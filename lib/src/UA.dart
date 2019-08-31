import 'package:events2/events2.dart';

import 'Constants.dart' as DartSIP_C;
import 'Registrator.dart';
import 'MediaSession.dart';
import 'Message.dart';
import 'Transactions.dart' as Transactions;
import 'Transport.dart';
import 'Utils.dart' as Utils;
import 'Exceptions.dart' as Exceptions;
import 'URI.dart';
import 'Parser.dart' as Parser;
import 'Config.dart' as config;
import 'Timers.dart';
import 'sanityCheck.dart';
import 'SIPMessage.dart' as SIPMessage;
import 'logger.dart';

class C {
  // UA status codes.
  static const STATUS_INIT = 0;
  static const STATUS_READY = 1;
  static const STATUS_USER_CLOSED = 2;
  static const STATUS_NOT_READY = 3;

  // UA error codes.
  static const CONFIGURATION_ERROR = 1;
  static const NETWORK_ERROR = 2;
}

class DynamicSettings {
  bool register = false;
}

class Contact {
  var pub_gruu;
  var temp_gruu;
  var anonymous = false;
  var outbound = false;
  var uri;
  Contact(this.uri);

  toString() {
    var contact = '<';

    if (anonymous) {
      contact +=
          this.temp_gruu ?? 'sip:anonymous@anonymous.invalid;transport=ws';
    } else {
      contact += this.pub_gruu ?? this.uri.toString();
    }

    if (outbound &&
        (anonymous ? this.temp_gruu == null : this.pub_gruu == null)) {
      contact += ';ob';
    }

    contact += '>';
    return contact;
  }
}

/**
 * The User-Agent class.
 * @class DartSIP.UA
 * @param {Object} configuration Configuration parameters.
 * @throws {DartSIP.Exceptions.ConfigurationError} If a configuration parameter is invalid.
 * @throws {TypeError} If no configuration is given.
 */
class UA extends EventEmitter {
  var _cache;
  var _configuration;
  var _dynConfiguration;
  var _dialogs;
  var _applicants;
  var _sessions = {};
  var _transport;
  var _contact;
  var _status;
  var _error;
  var _transactions;
  var _data;
  var _closeTimer;
  var _registrator;
  final logger = new Logger('UA');
  debug(msg) => logger.debug(msg);
  debugerror(error) => logger.error(error);

  UA(configuration) {
    debug('new() [configuration:${configuration.toString()}]');

    this._cache = {'credentials': {}};

    this._configuration = config.settings;
    this._dynConfiguration = new DynamicSettings();
    this._dialogs = {};

    // User actions outside any session/dialog (MESSAGE).
    this._applicants = {};

    this._sessions = {};
    this._transport = null;
    this._contact = null;
    this._status = C.STATUS_INIT;
    this._error = null;
    this._transactions = {'nist': {}, 'nict': {}, 'ist': {}, 'ict': {}};

    // Custom UA empty object for high level use.
    this._data = {};

    this._closeTimer = null;

    // Check configuration argument.
    if (configuration == null) {
      throw new Exceptions.ConfigurationError('Not enough arguments');
    }

    // Load configuration.
    try {
      this._loadConfig(configuration);
    } catch (e) {
      this._status = C.STATUS_NOT_READY;
      this._error = C.CONFIGURATION_ERROR;
      throw e;
    }

    // Initialize registrator.
    this._registrator = new Registrator(this);
  }

  get status => this._status;

  get contact => this._contact;

  get configuration => this._configuration;

  get transport => this._transport;

  // ============
  //  High Level API
  // ============

  /**
   * Connect to the server if status = STATUS_INIT.
   * Resume UA after being closed.
   */
  start() {
    debug('start()');

    if (this._status == C.STATUS_INIT) {
      this._transport.connect();
    } else if (this._status == C.STATUS_USER_CLOSED) {
      debug('restarting UA');

      // Disconnect.
      if (this._closeTimer != null) {
        clearTimeout(this._closeTimer);
        this._closeTimer = null;
        this._transport.disconnect();
      }

      // Reconnect.
      this._status = C.STATUS_INIT;
      this._transport.connect();
    } else if (this._status == C.STATUS_READY) {
      debug('UA is in READY status, not restarted');
    } else {
      debug(
          'ERROR: connection is down, Auto-Recovery system is trying to reconnect');
    }

    // Set dynamic configuration.
    this._dynConfiguration.register = this._configuration.register;
  }

  /**
   * Register.
   */
  register() {
    debug('register()');
    this._dynConfiguration.register = true;
    this._registrator.register();
  }

  /**
   * Unregister.
   */
  unregister({unregister_all = false}) {
    debug('unregister()');

    this._dynConfiguration.register = false;
    this._registrator.unregister(unregister_all);
  }

  /**
   * Get the Registrator instance.
   */
  registrator() {
    return this._registrator;
  }

  /**
   * Registration state.
   */
  isRegistered() {
    return this._registrator.registered;
  }

  /**
   * Connection state.
   */
  isConnected() {
    return this._transport.isConnected();
  }

  /**
   * Make an outgoing call.
   *
   * -param {String} target
   * -param {Object} [options]
   *
   * -throws {TypeError}
   *
   */
  call(target, options) {
    debug('call()');
    if (this._configuration.session_factory != null) {
      var session = this._configuration.session_factory.createSession(this);
      session.connect(target, options);
      return session;
    } else {
      throw new Exceptions.NotSupportedError("SessionFactory [this._configuration.session_factory] doesn't exist!");
    }
  }

  /**
   * Send a message.
   *
   * -param {String} target
   * -param {String} body
   * -param {Object} [options]
   *
   * -throws {TypeError}
   *
   */
  sendMessage(target, body, options) {
    debug('sendMessage()');
    var message = new Message(this);
    message.send(target, body, options);
    return message;
  }

  /**
   * Terminate ongoing sessions.
   */
  terminateSessions(options) {
    debug('terminateSessions()');
    this._sessions.forEach((idx, value) {
      if (!this._sessions[idx].isEnded()) {
        this._sessions[idx].terminate(options);
      }
    });
  }

  /**
   * Gracefully close.
   *
   */
  stop() {
    debug('stop()');

    // Remove dynamic settings.
    this._dynConfiguration = {};

    if (this._status == C.STATUS_USER_CLOSED) {
      debug('UA already closed');

      return;
    }

    // Close registrator.
    this._registrator.close();

    // If there are session wait a bit so CANCEL/BYE can be sent and their responses received.
    var num_sessions = this._sessions.length;

    // Run  _terminate_ on every Session.
    this._sessions.forEach((session, _) {
      if (this._sessions.containsKey(session)) {
        debug('closing session ${session}');
        try {
          this._sessions[session].terminate();
        } catch (error) {}
      }
    });

    // Run  _close_ on every applicant.
    for (var applicant in this._applicants) {
      if (this._applicants.containsKey(applicant))
        try {
          this._applicants[applicant].close();
        } catch (error) {}
    }

    this._status = C.STATUS_USER_CLOSED;

    var num_transactions = this._transactions['nict'].length +
        this._transactions['nist'].length +
        this._transactions['ict'].length +
        this._transactions['ist'].length;

    if (num_transactions == 0 && num_sessions == 0) {
      this._transport.disconnect();
    } else {
      this._closeTimer = setTimeout(
          () => () {
                this._closeTimer = null;
                this._transport.disconnect();
              },
          2000);
    }
  }

  /**
   * Normalice a string into a valid SIP request URI
   * -param {String} target
   * -returns {DartSIP.URI|null}
   */
  normalizeTarget(target) {
    return Utils.normalizeTarget(target, this._configuration.hostport_params);
  }

  /**
   * Allow retrieving configuration and autogenerated fields in runtime.
   */
  get(parameter) {
    switch (parameter) {
      case 'realm':
        return this._configuration.realm;

      case 'ha1':
        return this._configuration.ha1;

      default:
        debugerror('get() | cannot get "${parameter}" parameter in runtime');

        return null;
    }
  }

  /**
   * Allow configuration changes in runtime.
   * Returns true if the parameter could be set.
   */
  set(parameter, value) {
    switch (parameter) {
      case 'password':
        {
          this._configuration.password = value.toString();
          break;
        }

      case 'realm':
        {
          this._configuration.realm = value.toString();
          break;
        }

      case 'ha1':
        {
          this._configuration.ha1 = value.toString();
          // Delete the plain SIP password.
          this._configuration.password = null;
          break;
        }

      case 'display_name':
        {
          this._configuration.display_name = value;
          break;
        }

      default:
        debugerror('set() | cannot set "${parameter}" parameter in runtime');

        return false;
    }

    return true;
  }

  // ==================
  // Event Handlers.
  // ==================

  /**
   * new Transaction
   */
  newTransaction(transaction) {
    this._transactions[transaction.type][transaction.id] = transaction;
    this.emit('newTransaction', {'transaction': transaction});
  }

  /**
   * Transaction destroyed.
   */
  destroyTransaction(transaction) {
    this._transactions[transaction.type].remove(transaction.id);
    this.emit('transactionDestroyed', {'transaction': transaction});
  }

  /**
   * new Dialog
   */
  newDialog(dialog) {
    this._dialogs[dialog.id] = dialog;
  }

  /**
   * Dialog destroyed.
   */
  destroyDialog(dialog) {
    this._dialogs.remove(dialog.id);
  }

  /**
   *  new Message
   */
  newMessage(message, data) {
    this._applicants[message] = message;
    this.emit('newMessage', data);
  }

  /**
   *  Message destroyed.
   */
  destroyMessage(message) {
    this._applicants.remove(message);
  }

  /**
   * new RTCSession
   */
  newRTCSession(session, data) {
    this._sessions[session.id] = session;
    this.emit('newRTCSession', data);
  }

  /**
   * RTCSession destroyed.
   */
  destroyRTCSession(session) {
    this._sessions.remove([session.id]);
  }

  /**
   * Registered
   */
  registered(data) {
    this.emit('registered', data);
  }

  /**
   * Unregistered
   */
  unregistered(data) {
    this.emit('unregistered', data);
  }

  /**
   * Registration Failed
   */
  registrationFailed(data) {
    this.emit('registrationFailed', data);
  }

  // =================
  // ReceiveRequest.
  // =================

  /**
   * Request reception
   */
  receiveRequest(request) {
    var method = request.method;

    // Check that request URI points to us.
    if (request.ruri.user != this._configuration.uri.user &&
        request.ruri.user != this._contact.uri.user) {
      debug('Request-URI does not point to us');
      if (request.method != DartSIP_C.ACK) {
        request.reply_sl(404);
      }

      return;
    }

    // Check request URI scheme.
    if (request.ruri.scheme == DartSIP_C.SIPS) {
      request.reply_sl(416);

      return;
    }

    // Check transaction.
    if (Transactions.checkTransaction(this, request)) {
      return;
    }

    // Create the server transaction.
    if (method == DartSIP_C.INVITE) {
      /* eslint-disable no-new */
      new Transactions.InviteServerTransaction(this, this._transport, request);
      /* eslint-enable no-new */
    } else if (method != DartSIP_C.ACK && method != DartSIP_C.CANCEL) {
      /* eslint-disable no-new */
      new Transactions.NonInviteServerTransaction(
          this, this._transport, request);
      /* eslint-enable no-new */
    }

    /* RFC3261 12.2.2
     * Requests that do not change in any way the state of a dialog may be
     * received within a dialog (for example, an OPTIONS request).
     * They are processed as if they had been received outside the dialog.
     */
    if (method == DartSIP_C.OPTIONS) {
      request.reply(200);
    } else if (method == DartSIP_C.MESSAGE) {
      if (this.listeners('newMessage') == null) {
        request.reply(405);
        return;
      }
      var message = new Message(this);
      message.init_incoming(request);
    } else if (method == DartSIP_C.INVITE) {
      // Initial INVITE.
      if (!request.to_tag && this.listeners('newRTCSession').length == 0) {
        request.reply(405);

        return;
      }
    }

    var dialog;
    var session;

    // Initial Request.
    if (request.to_tag == null) {
      switch (method) {
        case DartSIP_C.INVITE:
          if (SessionFactory.supportWebRTC() &&
              this._configuration.session_factory != null) {
            if (request.hasHeader('replaces')) {
              var replaces = request.replaces;

              dialog = this._findDialog(
                  replaces.call_id, replaces.from_tag, replaces.to_tag);
              if (dialog != null) {
                session = dialog.owner;
                if (!session.isEnded()) {
                  session.receiveRequest(request);
                } else {
                  request.reply(603);
                }
              } else {
                request.reply(481);
              }
            } else {
              session = this._configuration.session_factory.createSession(this);
              session.init_incoming(request);
            }
          } else {
            debugerror('INVITE received but WebRTC is not supported');
            request.reply(488);
          }
          break;
        case DartSIP_C.BYE:
          // Out of dialog BYE received.
          request.reply(481);
          break;
        case DartSIP_C.CANCEL:
          session = this
              ._findSession(request.call_id, request.from_tag, request.to_tag);
          if (session != null) {
            session.receiveRequest(request);
          } else {
            debug('received CANCEL request for a non existent session');
          }
          break;
        case DartSIP_C.ACK:
          /* Absorb it.
           * ACK request without a corresponding Invite Transaction
           * and without To tag.
           */
          break;
        case DartSIP_C.NOTIFY:
          // Receive new sip event.
          this.emit('sipEvent', {'event': request.event, 'request': request});
          request.reply(200);
          break;
        default:
          request.reply(405);
          break;
      }
    }
    // In-dialog request.
    else {
      dialog =
          this._findDialog(request.call_id, request.from_tag, request.to_tag);

      if (dialog != null) {
        dialog.receiveRequest(request);
      } else if (method == DartSIP_C.NOTIFY) {
        session = this
            ._findSession(request.call_id, request.from_tag, request.to_tag);
        if (session != null) {
          session.receiveRequest(request);
        } else {
          debug('received NOTIFY request for a non existent subscription');
          request.reply(481, 'Subscription does not exist');
        }
      }

      /* RFC3261 12.2.2
       * Request with to tag, but no matching dialog found.
       * Exception: ACK for an Invite request for which a dialog has not
       * been created.
       */
      else if (method != DartSIP_C.ACK) {
        request.reply(481);
      }
    }
  }

  // ============
  // Utils.
  // ============

  /**
   * Get the session to which the request belongs to, if any.
   */
  _findSession(call_id, from_tag, to_tag) {
    var sessionIDa = call_id + from_tag;
    var sessionA = this._sessions[sessionIDa];
    var sessionIDb = call_id + to_tag;
    var sessionB = this._sessions[sessionIDb];

    if (sessionA != null) {
      return sessionA;
    } else if (sessionB != null) {
      return sessionB;
    } else {
      return null;
    }
  }

  /**
   * Get the dialog to which the request belongs to, if any.
   */
  _findDialog(call_id, from_tag, to_tag) {
    var id = call_id + from_tag + to_tag;
    var dialog = this._dialogs[id];

    if (dialog != null) {
      return dialog;
    } else {
      id = call_id + to_tag + from_tag;
      dialog = this._dialogs[id];
      if (dialog != null) {
        return dialog;
      } else {
        return null;
      }
    }
  }

  _loadConfig(configuration) {
    // Check and load the given configuration.
    try {
      config.load(this._configuration, configuration);
    } catch (e) {
      throw e;
    }

    // Post Configuration Process.

    // Allow passing 0 number as display_name.
    if (this._configuration.display_name == 0) {
      this._configuration.display_name = '0';
    }

    // Instance-id for GRUU.
    if (this._configuration.instance_id == null) {
      this._configuration.instance_id = Utils.newUUID();
    }

    // Jssip_id instance parameter. Static random tag of length 5.
    this._configuration.jssip_id = Utils.createRandomToken(5);

    // String containing this._configuration.uri without scheme and user.
    var hostport_params = this._configuration.uri.clone();

    hostport_params.user = null;
    this._configuration.hostport_params = hostport_params
        .toString()
        .replaceAll(new RegExp(r'sip:', caseSensitive: false), '');

    // Transport.
    try {
      this._transport = new Transport(this._configuration.sockets, {
        // Recovery options.
        'max_interval': this._configuration.connection_recovery_max_interval,
        'min_interval': this._configuration.connection_recovery_min_interval
      });

      // Transport event callbacks.
      this._transport.onconnecting = onTransportConnecting;
      this._transport.onconnect = onTransportConnect;
      this._transport.ondisconnect = onTransportDisconnect;
      this._transport.ondata = onTransportData;
    } catch (e) {
      debugerror(e);
      throw new Exceptions.ConfigurationError(
          'sockets', this._configuration.sockets);
    }

    // Remove sockets instance from configuration object.
    //TODO:  need dispose??
    this._configuration.sockets = null;

    // Check whether authorization_user is explicitly defined.
    // Take 'this._configuration.uri.user' value if not.
    if (this._configuration.authorization_user == null) {
      this._configuration.authorization_user = this._configuration.uri.user;
    }

    // If no 'registrar_server' is set use the 'uri' value without user portion and
    // without URI params/headers.
    if (this._configuration.registrar_server == null) {
      var registrar_server = this._configuration.uri.clone();
      registrar_server.user = null;
      registrar_server.clearParams();
      registrar_server.clearHeaders();
      this._configuration.registrar_server = registrar_server;
    }

    // User no_answer_timeout.
    this._configuration.no_answer_timeout *= 1000;

    // Via Host.
    if (this._configuration.contact_uri != null) {
      this._configuration.via_host = this._configuration.contact_uri.host;
    }
    // Contact URI.
    else {
      this._configuration.contact_uri = new URI(
          'sip',
          Utils.createRandomToken(8),
          this._configuration.via_host,
          null,
          {'transport': 'ws'});
    }
    this._contact = new Contact(this._configuration.contact_uri);

    // Seal the configuration.
    /*
    var writable_parameters = [
      'password',
      'realm',
      'ha1',
      'display_name',
      'register'
    ];
    for (var parameter in this._configuration) {
      if (this._configuration.containsKey(parameter)) {
        if (writable_parameters.indexOf(parameter) != -1) {
          this._configuration[parameter] = {
            'writable': true,
            'configurable': false
          };
        } else {
          this._configuration[parameter] = {
            'writable': false,
            'configurable': false
          };
        }
      }
    }

    debug('configuration parameters after validation:');
    for (var parameter in this._configuration) {
      // Only show the user user configurable parameters.
      if (config.settings.containsKey(parameter)) {
        switch (parameter) {
          case 'uri':
          case 'registrar_server':
            debug('- ${parameter}: ${this._configuration[parameter]}');
            break;
          case 'password':
          case 'ha1':
            debug('- ${parameter}: NOT SHOWN');
            break;
          default:
            debug(
                '- ${parameter}: ${JSON.stringify(this._configuration[parameter])}');
        }
      }
    }
  */
    return;
  }

/**
 * Transport event handlers
 */

// Transport connecting event.
  onTransportConnecting(data) {
    debug('Transport connecting');
    this.emit('connecting', data);
  }

// Transport connected event.
  onTransportConnect(data) {
    debug('Transport connected');
    if (this._status == C.STATUS_USER_CLOSED) {
      return;
    }
    this._status = C.STATUS_READY;
    this._error = null;

    this.emit('connected', data);

    if (this._dynConfiguration.register) {
      this._registrator.register();
    }
  }

// Transport disconnected event.
  onTransportDisconnect(data) {
    // Run _onTransportError_ callback on every client transaction using _transport_.
    var client_transactions = ['nict', 'ict', 'nist', 'ist'];
    client_transactions.forEach((type) {
      this._transactions[type].forEach((id, transaction) {
        transaction.onTransportError();
      });
    });

    this.emit('disconnected', data);

    // Call registrator _onTransportClosed_.
    this._registrator.onTransportClosed();

    if (this._status != C.STATUS_USER_CLOSED) {
      this._status = C.STATUS_NOT_READY;
      this._error = C.NETWORK_ERROR;
    }
  }

// Transport data event.
  onTransportData(data) {
    var transport = data['transport'];
    var message = data['message'];

    message = Parser.parseMessage(message, this);

    if (message == null) {
      return;
    }

    if (this._status == C.STATUS_USER_CLOSED &&
        message is SIPMessage.IncomingRequest) {
      return;
    }

    // Do some sanity check.
    if (!sanityCheck(message, this, transport)) {
      return;
    }

    if (message is SIPMessage.IncomingRequest) {
      message.transport = transport;
      this.receiveRequest(message);
    } else if (message is SIPMessage.IncomingResponse) {
      /* Unike stated in 18.1.2, if a response does not match
    * any transaction, it is discarded here and no passed to the core
    * in order to be discarded there.
    */

      var transaction;

      switch (message.method) {
        case DartSIP_C.INVITE:
          transaction = this._transactions['ict'][message.via_branch];
          if (transaction != null) {
            transaction.receiveResponse(message);
          }
          break;
        case DartSIP_C.ACK:
          // Just in case ;-).
          break;
        default:
          transaction = this._transactions['nict'][message.via_branch];
          if (transaction != null) {
            transaction.receiveResponse(message);
          }
          break;
      }
    }
  }
}