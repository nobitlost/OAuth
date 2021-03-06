// MIT License
//
// Copyright 2017 Electric Imp
//
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

// Authorization service default poll period
const OAUTH2_DEFAULT_POLL_TIME_SEC      = 300; // sec
// Default device flow grant type recommended by RFE
const OAUTH2_DEVICE_FLOW_GRANT_TYPE     = "urn:ietf:params:oauth:grant-type:device_code";
// Default access token time to live
const OAUTH2_TOKEN_DEFAULT_TTL          = 3600; // sec
// Default grant type for JWT authorization
const OAUTH2_JWT_GRANT_TYPE             = "urn:ietf:params:oauth:grant-type:jwt-bearer"
// OAuth2 Client possible states
enum Oauth2DeviceFlowState {
    IDLE,           // Default state, there is no network activity
    REQUEST_CODE,   // Request device and user codes
    WAIT_USER,      // Poll authorization server
    REFRESH_TOKEN   // Refreshing an access token
};

// The class that introduces OAuth2 namespace
class OAuth2 {
    static VERSION = "2.0.0";
}

// The class that represents OAuth 2.0 authorization flow
// with JSON Web Token.
// https://tools.ietf.org/html/rfc7523
class  OAuth2.JWTProfile {

    Client = class {

        // OAuth2 provider's token endpoint
        _tokenHost = null;

        // Issuer of the JWT
        _iss = null;
        // The scope of the access
        // https://tools.ietf.org/html/rfc6749#section-3.3
        _scope = null;
        // Private key for JWT sign
        _jwtSignKey = null;
        // Subject of the JWT
        _sub = null;

        // Credentials used to access protected resources
        _accessToken = null;
        // Access token death time
        _expiresAt = 0;

        // Debug mode, records non-error events
        _debug = false;

        // Client constructor.
        // Parameters:
        //      provider    OAuth2 provider configuration
        //                  Must be a table with following set of strings:
        //                      tokenHost   - provider's token endpoint URI
        //      params      Client specific parameters
        //                  Must be a table with following set of strings:
        //                      iss         - JWT issuer
        //                      scope       - authorization scope
        //                      jwtSignKey  - JWT sign secret key
        //                      sub         - [optional] the subject of the JWT
        constructor(provider, user) {
             if (!("tokenHost" in provider) ) {
                throw "Invalid Provider";
            }
            _tokenHost = provider.tokenHost;

             if (!("iss" in user)    ||
                 !("scope" in  user) ||
                 !("jwtSignKey" in user)) {
                throw "Invalid user config";
            }

            _iss = user.iss;
            // mandatory field but GOOGLE skips it
            if ("sub" in user) {
                _sub = user.sub;
            } else {
                _sub = _iss;
            }

            _scope = user.scope;
            _jwtSignKey = user.jwtSignKey;
        }

        // Returns access token string nonblocking way.
        // Returns:
        //      Access token as string object
        //      Null if the client is not authorized or token is expired
        function getValidAccessTokenOrNull() {
            if (isTokenValid()) {
                return _accessToken;
            } else {
                return null;
            }
        }

        // Checks if access token is valid
        function isTokenValid() {
            return date().time < _expiresAt;
        }

        // Starts access token acquisition procedure.
        //
        // Parameters:
        //          tokenReadyCallback  - The handler to be called when access token is acquired
        //                                or error is observed. The handle's signature:
        //                                  tokenReadyCallback(token, error), where
        //                                      token   - access token string
        //                                      error   - error description string
        //
        // Returns: Nothing
        //
        function acquireAccessToken(tokenReadyCallback) {
            if (isTokenValid()) {
                tokenReadyCallback(_accessToken, null);
                return;
            }

            local header = _urlsafe(http.base64encode("{\"alg\":\"RS256\",\"typ\":\"JWT\"}"));
            local claimset = {
                "iss"   : _iss,
                "scope" : _scope,
                "sub"   : _sub,
                "aud"   : _tokenHost,
                "exp"   : (time() + OAUTH2_TOKEN_DEFAULT_TTL),
                "iat"   : time()
            };
            local body = _urlsafe(http.base64encode(http.jsonencode(claimset)));

            local context = {
                "client": this,
                "userCallback": tokenReadyCallback
            };

            crypto.sign(crypto.RSASSA_PKCS1_SHA256, header + "." + body, _decodePem(_jwtSignKey),
                function(err, sig) {
                    if (err) {
                        _error(err);
                        return;
                    }

                    local signature = _urlsafe(http.base64encode(sig));
                    local oauthreq = http.urlencode({
                        "grant_type" : OAUTH2_JWT_GRANT_TYPE,
                        "assertion"  : (header + "." + body + "." + signature)
                    });

                    _log("Making a request to the host: " + _tokenHost);
                    _log((header + "." + body + "." + signature));

                    // Post, get the token
                    local request = http.post(_tokenHost, {}, oauthreq);
                    _log("Calling token host");
                    request.sendasync(_doTokenCallback.bindenv(context));

                }.bindenv(this)
            );
        }

        // -------------------- PRIVATE METHODS -------------------- //

        // Remove the armor, concatenate the lines, and base64 decode the text.
        function _decodePem(str) {
            local lines = split(str, "\n");
            // We really ought to iterate over the array until we find a starting line,
            // and then look for the matching ending line.
            if ((lines[0] == "-----BEGIN PRIVATE KEY-----"
                    && lines[lines.len() - 1] == "-----END PRIVATE KEY-----") ||
                (lines[0] == "-----BEGIN RSA PRIVATE KEY-----"
                    && lines[lines.len() - 1] == "-----END RSA PRIVATE KEY-----") ||
                (lines[0] == "-----BEGIN PUBLIC KEY-----"
                    && lines[lines.len() - 1] == "-----END PUBLIC KEY-----"))
            {
                local all = lines.slice(1, lines.len() - 1).reduce(@(a, b) a + b);
                return http.base64decode(all);
            }
            return null;
        }

        // Processes response from OAuth provider
        // Parameters:
        //          resp  - httpresponse instance
        //
        // Returns: Nothing
        function _doTokenCallback(resp) {
            if (resp.statuscode == 200) {
                // Cache the new token, pull in the expiry a little just in case
                local response = http.jsondecode(resp.body);
                local err = client._extractToken(response);
                userCallback(client._accessToken, err);
            } else {
                // Error getting token
                local mess = "Error getting token: " + resp.statuscode + " " + resp.body;
                client._log(mess);
                userCallback(null, mess);
            }
        }

        // Extracts data from  token request response
        // Parameters:
        //      respData    - a table parsed from http response body
        //
        // Returns:
        //      error description if the table doesn't contain required keys,
        //      Null otherwise
        function _extractToken(respData) {
            if (!("access_token"  in respData)) {
                    return "Response doesn't contain all required data";
            }

            _accessToken     = respData.access_token;

            if ("expires_in" in respData) {
                _expiresAt       = respData.expires_in + date().time;
            } else {
                _expiresAt       = OAUTH2_TOKEN_DEFAULT_TTL + date().time;
            }

            return null;
        }


        // Make already base64 encoded string URL safe
        function _urlsafe(s) {
            // Replace "+" with "-" and "/" with "_"
            while(1) {
                local p = s.find("+");
                if (p == null) break;
                s = s.slice(0,p) + "-" + s.slice(p+1);
            }
            while(1) {
                local p = s.find("/");
                if (p == null) break;
                s = s.slice(0,p) + "_" + s.slice(p+1);
            }
            return s;
        }

        // Records non-error event
        function _log(message) {
            if (_debug) {
                server.log("[OAuth2JWTProfile] " + message);
            }
        }

        // Records error event
        function _error(message) {
            server.error("[OAuth2JWTProfile] " + message);
        }

    }
}

// The class that represents OAuth 2.0 authorization flow
// for browserless and input constrained devices.
// https://tools.ietf.org/html/draft-ietf-oauth-device-flow-05
class OAuth2.DeviceFlow {

    // Predefined configuration for Google Authorization service
    GOOGLE =  {
        "loginHost" : "https://accounts.google.com/o/oauth2/device/code",
        "tokenHost" : "https://www.googleapis.com/oauth2/v4/token",
        "grantType" : "http://oauth.net/grant_type/device/1.0",
    };

    // The class that represents OAuth2 Client role.
    Client = class  {

        // Current number of issued token
        _currentTokenId  = 0;
        // The verification URI on the authorization server
        _verificationUrl = null;
        // The user verification code
        _userCode        = null;
        // The device verification code
        _deviceCode      = null;
        // Credentials used to access protected resources
        _accessToken     = null;
        // Credentials used to obtain access tokens
        _refreshToken    = null;
        // Interval between polling requests to the token endpoint
        _pollTime        = OAUTH2_DEFAULT_POLL_TIME_SEC;
        // Access token death time
        _expiresAt       = 0;
        // Timer used for polling requests
        _pollTimer       = null;

        // Status of a Client
        _status          = Oauth2DeviceFlowState.IDLE;

        // Client password
        _clientSecret    = null;
        // The client identifier.
        // https://tools.ietf.org/html/rfc6749#section-2.2
        _clientId        = null;
        // The scope of the access
        // https://tools.ietf.org/html/rfc6749#section-3.3
        _scope           = null;

        // OAuth2 provider's device authorization endpoint
        _loginHost       = null;
        // OAuth2 provider's token endpoint
        _tokenHost       = null;
        // OAuth2 grant type
        _grantType       = OAUTH2_DEVICE_FLOW_GRANT_TYPE;

        // Debug mode, records non-error events
        _debug          = true;

        // Client constructor.
        // Parameters:
        //      provider    OAuth2 provider configuration
        //                  Must be a table with following set of strings:
        //                      loginHost   - provider's device authorization endpoint URI
        //                      tokenHost   - provider's token endpoint URI
        //                      grantType   - [optional] grant type
        //      params      Client specific parameters
        //                  Must be a table with following set of strings:
        //                      clientId    - client identifier
        //                      scope       - authorization scope
        //                      clientSecret- [optional] client secret (password)
        constructor(provider, params) {
            if ( !("loginHost" in provider) ||
                 !("tokenHost" in provider) ) {
                     throw "Invalid Provider";
            }
            _loginHost = provider.loginHost;
            _tokenHost = provider.tokenHost;

            if ("grantType" in provider) _grantType = provider.grantType;

            if (!("clientId" in params) || !("scope" in params)) throw "Invalid Config";

            // not mandatory by RFE
            if ("clientSecret" in params) _clientSecret = params.clientSecret;

            _clientId = params.clientId;
            _scope = params.scope;
        };

        // Returns access token string nonblocking way.
        // Returns:
        //      Access token as string object
        //      Null if the client is not authorized or token is expired
        function getValidAccessTokenOrNull() {
            if (isAuthorized() && isTokenValid()) {
                return _accessToken;
            } else {
                return null;
            }
        }

        // Checks if access token is valid
        function isTokenValid() {
            return date().time < _expiresAt;
        }

        // Checks if client is authorized and able to refresh expired access token
        function isAuthorized() {
            return _refreshToken != null;
        }

        // Starts access token acquisition procedure.
        // Depending on Client state may starts full client authorization procedure or just token refreshing.
        //
        // Parameters:
        //          tokenReadyCallback  - The handler to be called when access token is acquired
        //                                or error is observed. The handle's signature:
        //                                  tokenReadyCallback(token, error), where
        //                                      token   - access token string
        //                                      error   - error description string
        //
        //          notifyUserCallback  - The handler to be called when user action is required.
        //                                  https://tools.ietf.org/html/draft-ietf-oauth-device-flow-05#section-3.3
        //                                  The handler's signature:
        //                                      notifyUserCallback(verification_uri, user_code), where
        //                                          verification_uri  - the URI the user need to use for client authorization
        //                                          user_code         - the code the user need to use somewhere at authorization server
        //
        //          force               - [optional] the directive to start new acquisition procedure even if previous request is not complete
        //
        // Returns:
        //          Null if no error was observed or
        //          error description in case of client is already performing request and no "force" directive is set
        //
        function acquireAccessToken(tokenReadyCallback, notifyUserCallback, force = false) {
            if (_isBusy() && !force) return "Token request is ongoing";

            if (isAuthorized()) {
                if (isTokenValid()) {
                     tokenReadyCallback(_accessToken, null);
                     return null;
                }
                else return refreshAccessToken(tokenReadyCallback);
            } else {
                return _requestCode(tokenReadyCallback, notifyUserCallback);
            }
        }

        // Starts token refresh procedure.
        // Parameters:
        //          cb  - The handler to be called when access token is acquired
        //                or error is observed. The handle's signature:
        //                     tokenReadyCallback(token, error), where
        //                          token   - access token string
        //                          error   - error description string
        // Returns error description if the client is unauthorized or Null
        function refreshAccessToken(cb) {
             if (!isAuthorized()) {
                 return "Unauthorized";
             }

             if (_isBusy()) {
                 _log("Resetting ongoing session with token id: " + _currentTokenId);
                 // incrementing the token # to cancel the previous one
                 _currentTokenId++;
             }

            local data = {
                "client_secret" : _clientSecret,
                "client_id"     : _clientId,
                "refresh_token" : _refreshToken,
                "grant_type"    : "refresh_token",
            };

            _doPostWithHttpCallback(_tokenHost, data, _doRefreshTokenCallback, [cb]);
            _changeStatus(Oauth2DeviceFlowState.REFRESH_TOKEN);

            return null;
        }


        // -------------------- PRIVATE METHODS -------------------- //

        // Sends Device Authorization Request to provider's device authorization endpoint.
        // Parameters:
        //          tokenReadyCallback  - The handler to be called when access token is acquired
        //                                or error is observed. The handle's signature:
        //                                  tokenReadyCallback(token, error), where
        //                                      token   - access token string
        //                                      error   - error description string
        //
        //          notifyUserCallback  -  The handler to be called when user action is required.
        //                                  https://tools.ietf.org/html/draft-ietf-oauth-device-flow-05#section-3.3
        //                                  The handler's signature:
        //                                      notifyUserCallback(verification_uri, user_code), where
        //                                          verification_uri  - the URI the user need to use for client authorization
        //                                          user_code         - the code the user need to use somewhere at authorization server
        //
        function _requestCode(tokenCallback, notifyUserCallback) {
            if (_isBusy()) {
                 _log("Resetting ongoing session with token id: " + _currentTokenId);
                 _reset();
            }

            // incrementing the token # to cancel the previous one
            _currentTokenId++;

            local data = {
                "scope": _scope,
                "client_id": _clientId,
            };

            _doPostWithHttpCallback(_loginHost, data, _requestCodeCallback,
                                    [tokenCallback, notifyUserCallback]);
            _changeStatus(Oauth2DeviceFlowState.REQUEST_CODE);

            return null;
        }

        // Device Authorization Response handler.
        // Parameters:
        //          resp                - httpresponse object
        //          tokenReadyCallback  - The handler to be called when access token is acquired
        //                                or error is observed. The handle's signature:
        //                                  tokenReadyCallback(token, error), where
        //                                      token   - access token string
        //                                      error   - error description string
        //
        //          notifyUserCallback  -  The handler to be called when user action is required.
        //                                  https://tools.ietf.org/html/draft-ietf-oauth-device-flow-05#section-3.3
        //                                  The handler's signature:
        //                                      notifyUserCallback(verification_uri, user_code), where
        //                                          verification_uri  - the URI the user need to use for client authorization
        //                                          user_code         - the code the user need to use somewhere at authorization server
        // Returns: Nothing
        function _requestCodeCallback(resp, cb, notifyUserCallback) {
            try {
                local respData = http.jsondecode(resp.body);
                if (null != _extractPollData(respData)) {
                    _reset();
                    _log("Something went wrong during code request: " + resp.body);
                    cb(null, resp.body);
                    return;
                }

                _changeStatus(Oauth2DeviceFlowState.WAIT_USER);

                if (notifyUserCallback) notifyUserCallback(_verificationUrl, _userCode);

                _schedulePoll(cb);

            } catch (error) {
                _reset();
                local msg = "Provider data processing error: " + error;
                _log(msg);
                cb(null, msg);
            }
        }

        // Token refresh response handler
        // Parameters:
        //          resp  - httpresponse object
        //          cb    - The handler to be called when access token is acquired
        //                  or error is observed. The handle's signature:
        //                     tokenReadyCallback(token, error), where
        //                          token   - access token string
        //                          error   - error description string
        // Returns: Nothing
        function _doRefreshTokenCallback(resp, cb) {
            try {
                _changeStatus(Oauth2DeviceFlowState.IDLE);
                local respData = http.jsondecode(resp.body);
                if (null != _extractToken(respData)) {
                    _reset();
                    _log("Something went wrong during refresh: " + resp.body);
                    cb(null, resp.body);
                } else {
                    cb(_accessToken, null);
                }
            } catch (error) {
                _reset();
                local msg = "Token refreshing error: " + error;
                _log(msg);
                cb(null, msg);
            }
        }

        // Sends Device Access Token Request to provider's token host.
        //          cb  - The handler to be called when access token is acquired
        //                 or error is observed. The handle's signature:
        //                    tokenReadyCallback(token, error), where
        //                        token   - access token string
        //                        error   - error description string
        // Returns:
        //      error description if Client doesn't wait device authorization from the user
        //                        or if time to wait for user action has expired,
        //      Null otherwise
        function _poll(cb) {
            // is it user call?
            if (_status != Oauth2DeviceFlowState.WAIT_USER) {
                return "Invalid status. Do not call _poll directly";
            }

            if (date().time > _expiresAt) {
                _reset();
                local msg = "Token acquiring timeout";
                _log(msg);
                cb(null, msg);
                return msg;
            }

            local data = {
                "client_id"     : _clientId,
                "code"          : _deviceCode,
                "grant_type"    : _grantType,
            };

            if (null != _clientSecret)  data.client_secret <- _clientSecret;

            _doPostWithHttpCallback(_tokenHost, data, _doPollCallback, [cb]);
        }

        // Handles Device Access Token Response.
        //          resp  - httpresponse object
        //          cb    - The handler to be called when access token is acquired
        //                  or error is observed. The handle's signature:
        //                     tokenReadyCallback(token, error), where
        //                        token   - access token string
        //                        error   - error description string
        // Returns:
        //      error description if Client doesn't wait device authorization from the user
        //                        or if time to wait for user action has expired,
        //      Null otherwise
        function _doPollCallback(resp, cb) {
            try {
                local respData = http.jsondecode(resp.body);
                local statusCode = resp.statuscode;

                if (statusCode == 200) {
                    _log("Polling success");

                    if (null == _extractToken(respData)) {
                        _changeStatus(Oauth2DeviceFlowState.IDLE);

                        // release memory
                        _cleanUp(false);

                        cb(_accessToken, null);
                    } else {
                        _reset();
                        cb(null, "Invalid server response: " + respData.body);
                    }
                } else if ( (statusCode/100) == 4) {
                    local error = respData.error;
                    _log("Polling error:" + error);

                    if (error == "authorization_pending") {
                        _schedulePoll(cb);

                    } else if (error == "slow_down") {
                        _pollTime *= 2;
                        imp.wakeup(_pollTime, _poll.bindenv(this));
                    } else {
                        // all other errors are hard
                        _reset();
                        cb(null, error);
                    }
                } else {
                    local msg = "Unexpected server response code:" + statusCode;
                    _log(msg);
                    _reset();
                    cb(null, msg);
                }
            } catch (error) {
                local msg = "General server poll error: " + error;
                _reset();
                _log(msg);
                cb(null, msg);
            }
        }

        // Makes POST to given URL with provided body.
        // Parameters:
        //          url             - resource URL
        //          data            - request body
        //          callback        - The handler to process HTTP response
        //          callbackArgs    - additional arguments to the handler
        function _doPostWithHttpCallback(url, data, callback, callbackArgs) {
            local body = http.urlencode(data);
            local context = {
                "client" : this,
                "func"   : callback,
                "args"   : callbackArgs,
                "cnt"    : _currentTokenId
            };
            http.post(url, {}, body).sendasync(_doHttpCallback.bindenv(context));
        }

        // HTTP response intermediate handler.
        // Drops response if there is newest pending request.
        //
        // Parameters:
        //         resp -   httpresponse object
        //
        // Returns: Nothing
        function _doHttpCallback(resp) {
            if (cnt != client._currentTokenId) {
                client._log("Canceled session " + cnt);
                return;
            }
            local allArgs = [client, resp];
            allArgs.extend(args);
            func.acall(allArgs);
        }

        // Schedules next token request.
        // Parameters is the same as for _poll function
        function _schedulePoll(cb) {
            local cnt = _currentTokenId;
            local client = this;
            imp.wakeup(_pollTime, function() {
                if (cnt != client._currentTokenId) {
                    client._log("Canceled session " + cnt);
                    return;
                }
                client._poll(cb);
            });
        }

        // Extracts data from  Device Authorization Response
        // Parameters:
        //      respData    - a table parsed from http response body
        //
        // Returns:
        //      error description if the table doesn't contain required keys,
        //      Null otherwise
        function _extractPollData(respData) {
            if (!("verification_url" in respData) ||
                !("user_code"        in respData) ||
                !("device_code"      in respData)) {
                    return "Response doesn't contain all required data";
            }
            _verificationUrl = respData.verification_url;
            _userCode        = respData.user_code;
            _deviceCode      = respData.device_code;

            if ("interval"   in respData) _pollTime  = respData.interval;

            if("expires_in"  in respData) _expiresAt = respData.expires_in + date().time;
            else                          _expiresAt = date().time + OAUTH2_DEFAULT_POLL_TIME_SEC;

            return null;
        }

        // Extracts data from  token request response
        // Parameters:
        //      respData    - a table parsed from http response body
        //
        // Returns:
        //      error description if the table doesn't contain required keys,
        //      Null otherwise
        function _extractToken(respData) {
            if (!("access_token"  in respData)) {
                    return "Response doesn't contain all required data";
            }

            _accessToken     = respData.access_token;

            // there is no refresh_token after token refresh
            if ("refresh_token" in respData) {
                _refreshToken    = respData.refresh_token;
            }

            if ("expires_in" in respData) {
                _expiresAt       = respData.expires_in + date().time;
            } else {
                _expiresAt       = OAUTH2_TOKEN_DEFAULT_TTL + date().time;
            }

            return null;
        }

        // Checks if Client performs token request procedure
        function _isBusy() {
            return (_status != Oauth2DeviceFlowState.IDLE);
        }

        // Resets Client state
        function _reset() {
            _cleanUp();
            _changeStatus(Oauth2DeviceFlowState.IDLE);
        }

        // Changes Client status
        function _changeStatus(newStatus) {
            _log("Change status of session" + _currentTokenId + " from " + _status + " to " + newStatus);
            _status = newStatus;
        }

        // Clears client variables.
        // Parameters:
        //              full  - the directive to reset client to initial state.
        //                      Set to False if token information should be preserved.
        //  Returns:    Nothing
        function _cleanUp(full = true) {
            _verificationUrl = null;
            _userCode        = null;
            _deviceCode      = null;
            _pollTime        = OAUTH2_DEFAULT_POLL_TIME_SEC;
            _pollTimer       = null;
            _scope           = null;

            if (full) {
                _expiresAt       = null;
                _refreshToken    = null;
                _accessToken     = null;
            }
        }

        // Records non-error event
        function _log(txt) {
            if (_debug) {
                server.log("[OAuth2DeviceFlow] " + txt);
            }
        }
    } // end of Client
}