import Foundation

struct JavaScriptInjectionService {
    static func fillHelperScript() -> String {
        return """
        window.__ffb_setNativeValue = function(element, value) {
            const nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            nativeInputValueSetter.call(element, value);
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
        };

        window.__ffb_findUsername = function(customSel) {
            if (customSel) {
                const el = document.querySelector(customSel);
                if (el) return el;
            }
            const selectors = [
                'input[autocomplete="username"]',
                'input[autocomplete="email"]',
                'input[type="email"]',
                'input[name*="user" i]',
                'input[name*="email" i]',
                'input[name*="login" i]',
                'input[id*="user" i]',
                'input[id*="email" i]',
                'input[id*="login" i]',
                'input[placeholder*="email" i]',
                'input[placeholder*="user" i]',
                'input[type="text"]'
            ];
            for (const sel of selectors) {
                const el = document.querySelector(sel);
                if (el && el.offsetParent !== null) return el;
            }
            return null;
        };

        window.__ffb_findPassword = function(customSel) {
            if (customSel) {
                const el = document.querySelector(customSel);
                if (el) return el;
            }
            const selectors = [
                'input[autocomplete="current-password"]',
                'input[type="password"]',
                'input[name*="pass" i]',
                'input[id*="pass" i]'
            ];
            for (const sel of selectors) {
                const el = document.querySelector(sel);
                if (el && el.offsetParent !== null) return el;
            }
            return null;
        };

        window.__ffb_findSubmit = function(customSel) {
            if (customSel) {
                const el = document.querySelector(customSel);
                if (el) return el;
            }
            const selectors = [
                'button[type="submit"]',
                'input[type="submit"]',
                'button[name*="login" i]',
                'button[name*="sign" i]',
                'button[id*="login" i]',
                'button[id*="sign" i]',
                'button:has(> span)',
                '[role="button"]'
            ];
            for (const s of selectors) {
                const els = document.querySelectorAll(s);
                for (const el of els) {
                    if (el.offsetParent !== null) {
                        const text = (el.textContent || '').toLowerCase();
                        if (text.includes('log in') || text.includes('login') ||
                            text.includes('sign in') || text.includes('signin') ||
                            text.includes('submit') || text.includes('continue') ||
                            text.includes('next')) {
                            return el;
                        }
                    }
                }
            }
            const form = document.querySelector('form');
            if (form) {
                const btn = form.querySelector('button, input[type="submit"]');
                if (btn) return btn;
            }
            return null;
        };
        """
    }

    static func fillCredentialScript(
        username: String,
        password: String,
        usernameSelector: String?,
        passwordSelector: String?,
        suppressKeyboard: Bool = false
    ) -> String {
        let escapedUser = username.jsEscaped
        let escapedPass = password.jsEscaped
        let userSel = (usernameSelector?.isEmpty == false) ? usernameSelector!.jsEscaped : ""
        let passSel = (passwordSelector?.isEmpty == false) ? passwordSelector!.jsEscaped : ""
        let focusCall = suppressKeyboard ? "" : "el.focus();"
        let blurAfter = suppressKeyboard ? "if (document.activeElement && document.activeElement.blur) { document.activeElement.blur(); }" : ""

        return """
        (function() {
            const userField = window.__ffb_findUsername ? window.__ffb_findUsername('\(userSel)') : null;
            const passField = window.__ffb_findPassword ? window.__ffb_findPassword('\(passSel)') : null;
            const setVal = window.__ffb_setNativeValue || function(el, v) { el.value = v; el.dispatchEvent(new Event('input', {bubbles:true})); };
            const fillField = function(el, v) { \(focusCall) setVal(el, v); };
            let filled = 0;
            if (userField) { fillField(userField, '\(escapedUser)'); filled++; }
            if (passField) { fillField(passField, '\(escapedPass)'); filled++; }
            \(blurAfter)
            return JSON.stringify({ filled: filled, userFound: !!userField, passFound: !!passField });
        })();
        """
    }

    static func loginResponseObserverScript() -> String {
        return """
        (function() {
            try {
                if (window.__ffb_lrObserver) { try { window.__ffb_lrObserver.disconnect(); } catch(e){} }
                if (window.__ffb_lrTimer) { try { clearTimeout(window.__ffb_lrTimer); } catch(e){} }
                if (window.__ffb_lrTimeout) { try { clearTimeout(window.__ffb_lrTimeout); } catch(e){} }
                window.__ffb_lrFired = false;
                var post = function(kind, hint) {
                    if (window.__ffb_lrFired) return;
                    window.__ffb_lrFired = true;
                    try { if (window.__ffb_lrObserver) window.__ffb_lrObserver.disconnect(); } catch(e){}
                    try { if (window.__ffb_lrTimer) clearTimeout(window.__ffb_lrTimer); } catch(e){}
                    try { if (window.__ffb_lrTimeout) clearTimeout(window.__ffb_lrTimeout); } catch(e){}
                    try {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.loginResponse) {
                            window.webkit.messageHandlers.loginResponse.postMessage({ kind: kind, hint: hint || '' });
                        }
                    } catch (e) {}
                };
                var classify = function() {
                    try {
                        var bodyText = (document.body && document.body.innerText) ? document.body.innerText : '';
                        var lower = bodyText.toLowerCase();
                        var passField = document.querySelector('input[type="password"]');
                        var hasPassword = !!(passField && passField.offsetParent !== null);
                        if (lower.indexOf('been disabled') !== -1 || lower.indexOf('account is locked') !== -1 || lower.indexOf('account locked') !== -1) {
                            post('blocked', 'disabled');
                            return;
                        }
                        if (lower.indexOf('invalid') !== -1 || lower.indexOf('incorrect') !== -1 || lower.indexOf('wrong password') !== -1 || lower.indexOf('try again') !== -1) {
                            post('failed', 'invalid');
                            return;
                        }
                        if (bodyText.indexOf('Welcome!') !== -1 || lower.indexOf('dashboard') !== -1 || lower.indexOf('sign out') !== -1 || lower.indexOf('log out') !== -1) {
                            post('success', 'welcome');
                            return;
                        }
                        var path = window.location.pathname || '/';
                        if ((path === '' || path === '/') && !hasPassword) { post('success', 'homepage'); return; }
                    } catch (e) {}
                };
                var debounced = function() {
                    if (window.__ffb_lrTimer) clearTimeout(window.__ffb_lrTimer);
                    window.__ffb_lrTimer = setTimeout(classify, 350);
                };
                var obs = new MutationObserver(debounced);
                obs.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
                window.__ffb_lrObserver = obs;
                window.__ffb_lrTimeout = setTimeout(function() { post('timeout', ''); }, 6000);
                setTimeout(classify, 500);
                return JSON.stringify({ installed: true });
            } catch (e) {
                return JSON.stringify({ installed: false, error: String(e) });
            }
        })();
        """
    }

    static func submitFormScript(submitSelector: String?) -> String {
        let sel = (submitSelector?.isEmpty == false) ? submitSelector!.jsEscaped : ""

        return """
        (function() {
            const btn = window.__ffb_findSubmit ? window.__ffb_findSubmit('\(sel)') : null;
            if (btn) { btn.click(); return JSON.stringify({ submitted: true }); }
            const form = document.querySelector('form');
            if (form) { form.submit(); return JSON.stringify({ submitted: true, method: 'form' }); }
            return JSON.stringify({ submitted: false });
        })();
        """
    }

    static func detectLoginFormScript() -> String {
        return """
        (function() {
            const passFields = document.querySelectorAll('input[type="password"]');
            let hasVisible = false;
            passFields.forEach(f => { if (f.offsetParent !== null) hasVisible = true; });
            const forms = document.querySelectorAll('form');
            let formCount = 0;
            forms.forEach(f => { if (f.querySelector('input[type="password"]')) formCount++; });
            return JSON.stringify({
                hasLoginForm: hasVisible,
                passwordFieldCount: passFields.length,
                loginFormCount: formCount
            });
        })();
        """
    }

    /// Installs a MutationObserver that posts page state to native via the
    /// `rcrObserver` script-message handler. Accepts an optional per-domain
    /// success CSS selector from Site Settings for custom detection.
    static func rcrInstallObserverScript(successSelector: String? = nil) -> String {
        let sel = (successSelector?.isEmpty == false) ? successSelector!.jsEscaped : ""
        return """
        (function() {
            try {
                if (window.__ffb_rcrObserver) { try { window.__ffb_rcrObserver.disconnect(); } catch(e){} }
                if (window.__ffb_rcrTimer) { try { clearTimeout(window.__ffb_rcrTimer); } catch(e){} }
                var send = function() {
                    try {
                        var passField = document.querySelector('input[type="password"]');
                        var hasPassword = !!(passField && passField.offsetParent !== null);
                        var bodyText = (document.body && document.body.innerText) ? document.body.innerText : '';
                        var lower = bodyText.toLowerCase();
                        var hasWelcome = bodyText.indexOf('Welcome!') !== -1;
                        var hasDisabled = lower.indexOf('been disabled') !== -1;
                        var hasTempDisabled = (!hasDisabled) && (lower.indexOf('temporarily') !== -1);
                        var hasSuccess = false;
                        var sel = '\(sel)';
                        if (sel) {
                            try { hasSuccess = !!document.querySelector(sel); } catch(e) {}
                        }
                        if (!hasSuccess) {
                            hasSuccess = lower.indexOf('you are logged in') !== -1 ||
                                         (!!document.querySelector('[class*="success"]:not(script):not(style)'));
                        }
                        var path = window.location.pathname || '/';
                        var isHomepage = (path === '' || path === '/');
                        var url = window.location.href;
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rcrObserver) {
                            window.webkit.messageHandlers.rcrObserver.postMessage({
                                hasPassword: hasPassword,
                                hasWelcome: hasWelcome,
                                hasDisabled: hasDisabled,
                                hasTempDisabled: hasTempDisabled,
                                hasSuccess: hasSuccess,
                                isHomepage: isHomepage,
                                url: url
                            });
                        }
                    } catch (e) {}
                };
                var debounced = function() {
                    if (window.__ffb_rcrTimer) { clearTimeout(window.__ffb_rcrTimer); }
                    window.__ffb_rcrTimer = setTimeout(send, 450);
                };
                var obs = new MutationObserver(debounced);
                obs.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true });
                window.__ffb_rcrObserver = obs;
                setTimeout(send, 350);
                return JSON.stringify({ installed: true });
            } catch (e) {
                return JSON.stringify({ installed: false, error: String(e) });
            }
        })();
        """
    }

    static func rcrUninstallObserverScript() -> String {
        return """
        (function() {
            try { if (window.__ffb_rcrObserver) { window.__ffb_rcrObserver.disconnect(); } } catch(e){}
            window.__ffb_rcrObserver = null;
            if (window.__ffb_rcrTimer) { try { clearTimeout(window.__ffb_rcrTimer); } catch(e){} window.__ffb_rcrTimer = null; }
            return JSON.stringify({ uninstalled: true });
        })();
        """
    }

    static func extractFilledCredentialsScript() -> String {
        return """
        (function() {
            const passField = document.querySelector('input[type="password"]');
            if (!passField || !passField.value) return JSON.stringify({ found: false });
            let userField = null;
            const form = passField.closest('form');
            if (form) { userField = form.querySelector('input[type="email"], input[type="text"], input[autocomplete="username"]'); }
            if (!userField) { userField = document.querySelector('input[type="email"], input[autocomplete="username"]'); }
            return JSON.stringify({ found: true, username: userField ? userField.value : '', password: passField.value });
        })();
        """
    }
}

extension String {
    var jsEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
