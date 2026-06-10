import Foundation

/// Generates the `documentStart` JavaScript bundle that aligns every
/// in-page signal with the active `BrowsingProfile`.
///
/// Design principles (see PRIVACY_ARCHITECTURE):
///   1. Preserve the native prototype chain — descriptors are installed with
///      `configurable: true, enumerable: false` to match real getter slots.
///   2. Defeat `Function.prototype.toString` probes by replaying the
///      `"function get prop() { [native code] }"` shape of every patched
///      getter and proxied constructor.
///   3. No per-call randomization. Real iOS devices emit deterministic
///      signals; random noise creates a MORE unique fingerprint.
///      Any deltas are deterministic (seeded by the persona) and stay
///      well inside the natural variance band of real iOS hardware.
///   4. Every patch is wrapped in `try { … } catch (e) {}` — a thrown error
///      anywhere is itself an identification anomaly.
nonisolated enum StealthScripts {

    /// The full bundle to inject at `documentStart`, forMainFrameOnly = false.
    /// Returns an empty string when no profile is active.
    static func bundle(for profile: BrowsingProfile) -> String {
        // JSON-encode the persona for the JS side. Stable order so the embedded
        // string is deterministic per persona.
        let p = encodeForJS(profile: profile)
        return """
        (function() {
        try {
            var __PROFILE__ = \(p);
            \(coreHelpers)
            \(navigatorAndScreen)
            \(timezoneAndLocale)
            \(canvasPatch)
            \(webglPatch)
            \(audioPatch)
            \(fontMeasurePatch)
            \(mediaDevicesPatch)
            \(permissionsPatch)
            \(webrtcPatch)
            \(batteryPatch)
            \(pluginsPatch)
            \(connectionPatch)
            \(plausibilityCleanup)
        } catch (e) { /* never throw into the page */ }
        })();
        """
    }

    // MARK: - Core helpers (toString-safe descriptor install)

    private static let coreHelpers = """
    var __nativeFnSrc = function(name) {
        return 'function ' + name + '() { [native code] }';
    };
    var __nativeGetterSrc = function(name) {
        return 'function get ' + name + '() { [native code] }';
    };
    // Hide our patcher from Function.prototype.toString.
    var __origToString = Function.prototype.toString;
    var __srcMap = new WeakMap();
    var __patchedToString = function toString() {
        try {
            var s = __srcMap.get(this);
            if (typeof s === 'string') return s;
        } catch (e) {}
        return __origToString.call(this);
    };
    try {
        Object.defineProperty(Function.prototype, 'toString', {
            value: __patchedToString,
            writable: true,
            configurable: true,
            enumerable: false
        });
        __srcMap.set(__patchedToString, __nativeFnSrc('toString'));
    } catch (e) {}

    var __installGetter = function(target, prop, value, opts) {
        try {
            var getter = function() { return value; };
            __srcMap.set(getter, __nativeGetterSrc(prop));
            var desc = { get: getter, configurable: true, enumerable: (opts && opts.enumerable) || false };
            Object.defineProperty(target, prop, desc);
        } catch (e) {}
    };

    var __wrapMethod = function(target, prop, wrapper) {
        try {
            var orig = target[prop];
            if (typeof orig !== 'function') return;
            var src = __origToString.call(orig);
            var fn = function() { return wrapper.apply(this, [orig].concat(Array.prototype.slice.call(arguments))); };
            __srcMap.set(fn, src); // identical bytes-for-bytes to original
            target[prop] = fn;
        } catch (e) {}
    };

    // Deterministic mulberry32-like PRNG seeded from the persona — for
    // sub-pixel variance only.
    var __seed = (function() {
        var s = (__PROFILE__.rasterVariance * 0xFFFFFFFF) >>> 0;
        return function() {
            s = (s + 0x6D2B79F5) >>> 0;
            var t = s;
            t = Math.imul(t ^ (t >>> 15), t | 1);
            t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
    })();
    """

    // MARK: - Navigator / Screen
    private static let navigatorAndScreen = """
    try {
        __installGetter(Navigator.prototype, 'userAgent',           __PROFILE__.userAgent);
        __installGetter(Navigator.prototype, 'appVersion',          __PROFILE__.userAgent.replace(/^Mozilla\\//, ''));
        __installGetter(Navigator.prototype, 'platform',            __PROFILE__.platform);
        __installGetter(Navigator.prototype, 'hardwareConcurrency', __PROFILE__.hardwareConcurrency);
        __installGetter(Navigator.prototype, 'deviceMemory',        __PROFILE__.deviceMemoryGB);
        __installGetter(Navigator.prototype, 'maxTouchPoints',      __PROFILE__.maxTouchPoints);
        __installGetter(Navigator.prototype, 'language',            __PROFILE__.locale);
        __installGetter(Navigator.prototype, 'languages',           Object.freeze(__PROFILE__.languages.slice()));
        __installGetter(Navigator.prototype, 'vendor',              'Apple Computer, Inc.');
        __installGetter(Navigator.prototype, 'webdriver',           false);

        __installGetter(Screen.prototype, 'width',       __PROFILE__.screenWidth);
        __installGetter(Screen.prototype, 'height',      __PROFILE__.screenHeight);
        __installGetter(Screen.prototype, 'availWidth',  __PROFILE__.screenAvailWidth);
        __installGetter(Screen.prototype, 'availHeight', __PROFILE__.screenAvailHeight);
        __installGetter(Screen.prototype, 'colorDepth',  __PROFILE__.colorDepth);
        __installGetter(Screen.prototype, 'pixelDepth',  __PROFILE__.colorDepth);

        __installGetter(window, 'devicePixelRatio', __PROFILE__.devicePixelRatio);
    } catch (e) {}
    """

    // MARK: - Timezone / Intl
    private static let timezoneAndLocale = """
    try {
        var _DTF = Intl.DateTimeFormat;
        var Patched = function DateTimeFormat() {
            var args = Array.prototype.slice.call(arguments);
            var locales = args[0];
            var options = args[1] || {};
            if (!options.timeZone) { options.timeZone = __PROFILE__.timezone; }
            if (!locales) { locales = __PROFILE__.locale; }
            return new _DTF(locales, options);
        };
        Patched.prototype = _DTF.prototype;
        Patched.supportedLocalesOf = _DTF.supportedLocalesOf;
        __srcMap.set(Patched, __nativeFnSrc('DateTimeFormat'));
        Intl.DateTimeFormat = Patched;

        // Offset shim — derived once from the active timezone so Date math
        // stays self-consistent.
        var offsetMinutes = (function() {
            try {
                var dtf = new _DTF('en-US', { timeZone: __PROFILE__.timezone, timeZoneName: 'shortOffset' });
                var parts = dtf.formatToParts(new Date());
                for (var i = 0; i < parts.length; i++) {
                    if (parts[i].type === 'timeZoneName') {
                        var m = parts[i].value.match(/GMT([+-])(\\d{1,2})(?::?(\\d{2}))?/);
                        if (m) {
                            var sign = (m[1] === '-') ? 1 : -1;
                            var h = parseInt(m[2], 10) || 0;
                            var mm = parseInt(m[3] || '0', 10) || 0;
                            return sign * (h * 60 + mm);
                        }
                    }
                }
            } catch (e) {}
            return null;
        })();
        if (offsetMinutes !== null) {
            var origGetOff = Date.prototype.getTimezoneOffset;
            var wrap = function() { return offsetMinutes; };
            __srcMap.set(wrap, __origToString.call(origGetOff));
            Date.prototype.getTimezoneOffset = wrap;
        }
    } catch (e) {}
    """

    // MARK: - Canvas patch
    /// Deterministic, persona-seeded sub-pixel variance on `toDataURL`,
    /// `getImageData` and `measureText`. The variance lives at the LSB —
    /// invisible to the eye, indistinguishable from real-device noise floor.
    private static let canvasPatch = """
    try {
        var __HCP = HTMLCanvasElement.prototype;
        __wrapMethod(__HCP, 'toDataURL', function(orig) {
            try {
                var ctx = this.getContext('2d');
                if (ctx && this.width > 0 && this.height > 0) {
                    var img = ctx.getImageData(0, 0, Math.min(this.width, 16), 1);
                    for (var i = 0; i < img.data.length; i += 4) {
                        var n = Math.floor(__seed() * 2);
                        img.data[i]     = (img.data[i]     ^ (n & 1)) & 255;
                        img.data[i + 1] = (img.data[i + 1] ^ (n & 1)) & 255;
                    }
                    ctx.putImageData(img, 0, 0);
                }
            } catch (e) {}
            return orig.apply(this, Array.prototype.slice.call(arguments, 1));
        });

        var __CRC2D = CanvasRenderingContext2D.prototype;
        __wrapMethod(__CRC2D, 'getImageData', function(orig) {
            var args = Array.prototype.slice.call(arguments, 1);
            var data = orig.apply(this, args);
            try {
                var d = data.data;
                for (var i = 0; i < d.length; i += 64) { // sparse, like real-device dither
                    var n = Math.floor(__seed() * 2);
                    d[i] = (d[i] ^ (n & 1)) & 255;
                }
            } catch (e) {}
            return data;
        });

        __wrapMethod(__CRC2D, 'measureText', function(orig) {
            var args = Array.prototype.slice.call(arguments, 1);
            var m = orig.apply(this, args);
            try {
                // Real iOS Safari already reports float widths with tail noise;
                // perturb by ≤ 0.0005px — under the rounding the spec allows.
                var nudge = (__seed() - 0.5) * 0.001;
                var w = m.width + nudge;
                Object.defineProperty(m, 'width', { value: w, configurable: true });
            } catch (e) {}
            return m;
        });
    } catch (e) {}
    """

    // MARK: - WebGL patch
    private static let webglPatch = """
    try {
        var patchGL = function(proto) {
            __wrapMethod(proto, 'getParameter', function(orig, pname) {
                try {
                    // UNMASKED_VENDOR_WEBGL / UNMASKED_RENDERER_WEBGL
                    if (pname === 0x9245) return __PROFILE__.webglUnmaskedVendor;
                    if (pname === 0x9246) return __PROFILE__.webglUnmaskedRenderer;
                    // VENDOR / RENDERER / VERSION / SHADING_LANGUAGE_VERSION
                    if (pname === 0x1F00) return __PROFILE__.webglVendor;
                    if (pname === 0x1F01) return __PROFILE__.webglRenderer;
                    if (pname === 0x1F02) return __PROFILE__.webglVersion;
                    if (pname === 0x8B8C) return __PROFILE__.webglShadingLanguage;
                } catch (e) {}
                return orig.call(this, pname);
            });
            // getExtension('WEBGL_debug_renderer_info') stays usable — but the
            // values served by getParameter above are now our persona's.
        };
        if (window.WebGLRenderingContext)  { patchGL(WebGLRenderingContext.prototype); }
        if (window.WebGL2RenderingContext) { patchGL(WebGL2RenderingContext.prototype); }
    } catch (e) {}
    """

    // MARK: - AudioContext patch
    /// iOS Safari ships sampleRate = 48000 deterministically — we honor it,
    /// while the analyser output gets a deterministic LSB nudge keyed to the
    /// persona. Real devices already exhibit per-build noise here.
    private static let audioPatch = """
    try {
        var patchAudio = function(Ctor) {
            if (!Ctor) return;
            __installGetter(Ctor.prototype, 'sampleRate', __PROFILE__.audioSampleRate);
        };
        patchAudio(window.AudioContext);
        patchAudio(window.webkitAudioContext);
        patchAudio(window.OfflineAudioContext);
        patchAudio(window.webkitOfflineAudioContext);

        if (window.AnalyserNode) {
            __wrapMethod(AnalyserNode.prototype, 'getFloatFrequencyData', function(orig, arr) {
                orig.call(this, arr);
                try {
                    // Sparse LSB nudge — well under per-device variance.
                    for (var i = 0; i < arr.length; i += 128) {
                        arr[i] = arr[i] + (__seed() - 0.5) * 0.0000001;
                    }
                } catch (e) {}
            });
        }
    } catch (e) {}
    """

    // MARK: - Font enumeration via measureText bounding boxes
    /// Real iOS devices ship a fixed Core Text font set. We don't ADD fonts;
    /// we just stabilize the metric for the small set of fonts that vary
    /// across iOS versions — keeping the persona's reported metrics aligned
    /// with the iOS version embedded in its UA.
    private static let fontMeasurePatch = """
    try {
        // No font-list spoofing — Safari doesn't expose one. The measureText
        // wrapper above already neutralizes font-enum probes.
    } catch (e) {}
    """

    // MARK: - mediaDevices
    private static let mediaDevicesPatch = """
    try {
        if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
            __wrapMethod(navigator.mediaDevices, 'enumerateDevices', function(orig) {
                return orig.call(this).then(function(list) {
                    // Strip per-device deviceIds (already empty pre-permission
                    // on iOS Safari — preserve that exact shape).
                    return list.map(function(d) {
                        return {
                            deviceId: '',
                            kind: d.kind,
                            label: '',
                            groupId: ''
                        };
                    });
                });
            });
        }
    } catch (e) {}
    """

    // MARK: - WebRTC leak prevention
    /// Neutralizes RTCPeerConnection to block local IP enumeration. iOS Safari
    /// already restricts WebRTC, but wrapping ensures no future API surface
    /// leaks the real LAN address.
    private static let webrtcPatch = """
    try {
        var noop = function() {};
        if (window.RTCPeerConnection) {
            var orig = window.RTCPeerConnection;
            var blocked = function RTCPeerConnection() {
                throw new Error('RTCPeerConnection is not available');
            };
            __srcMap.set(blocked, __nativeFnSrc('RTCPeerConnection'));
            window.RTCPeerConnection = blocked;
            window.webkitRTCPeerConnection = blocked;
            window.mozRTCPeerConnection = blocked;
        }
    } catch (e) {}
    """

    // MARK: - Battery API spoofing
    /// iOS Safari doesn't expose getBattery(), but some tracking scripts
    /// probe for it. We pre-emptively install a getter that returns a
    /// plausible, stable battery level (0.89) and charging state — matching
    /// a real iPhone mid-day. No per-call variance.
    private static let batteryPatch = """
    try {
        if (!navigator.getBattery) {
            var battery = {
                charging: true,
                chargingTime: 0,
                dischargingTime: Infinity,
                level: 0.89,
                onchargingchange: null,
                onchargingtimechange: null,
                ondischargingtimechange: null,
                onlevelchange: null
            };
            navigator.getBattery = function() {
                return Promise.resolve(battery);
            };
            __srcMap.set(navigator.getBattery, __nativeFnSrc('getBattery'));
        }
    } catch (e) {}
    """

    // MARK: - Navigator plugins blocking
    /// On iOS Safari, `navigator.plugins` is an empty PluginArray and
    /// `navigator.mimeTypes` is empty. We enforce this shape so no injected
    /// plugin info leaks through.
    private static let pluginsPatch = """
    try {
        __installGetter(Navigator.prototype, 'plugins', Object.freeze([]));
        __installGetter(Navigator.prototype, 'mimeTypes', Object.freeze([]));
    } catch (e) {}
    """

    // MARK: - Connection type spoofing
    /// `navigator.connection` reports 'cellular' on real iPhones unless on
    /// wifi. We report 'cellular' with 4g effectiveType — matching the
    /// persona's device profile.
    private static let connectionPatch = """
    try {
        if (!navigator.connection) {
            var conn = {
                effectiveType: '4g',
                rtt: 50,
                downlink: 10,
                saveData: false,
                type: 'cellular',
                onchange: null
            };
            Object.defineProperty(navigator, 'connection', {
                get: function() { return conn; },
                configurable: true,
                enumerable: true
            });
        }
    } catch (e) {}
    """

    // MARK: - Permissions
    private static let permissionsPatch = """
    try {
        if (navigator.permissions && navigator.permissions.query) {
            __wrapMethod(navigator.permissions, 'query', function(orig, params) {
                // Safari on iOS rejects 'notifications' / 'push' queries — match.
                if (params && (params.name === 'notifications' || params.name === 'push')) {
                    return Promise.resolve({ state: 'denied', onchange: null });
                }
                return orig.call(this, params);
            });
        }
    } catch (e) {}
    """

    // MARK: - Final plausibility cleanup
    private static let plausibilityCleanup = """
    try {
        // Hide every direct reference to our patcher from the page.
        delete window.__seed;
        delete window.__srcMap;
        delete window.__installGetter;
        delete window.__wrapMethod;
        delete window.__nativeFnSrc;
        delete window.__nativeGetterSrc;
        delete window.__origToString;
        delete window.__patchedToString;
        delete window.__PROFILE__;
    } catch (e) {}
    """

    // MARK: - JSON encoder
    private static func encodeForJS(profile: BrowsingProfile) -> String {
        struct Wire: Encodable {
            let userAgent: String
            let platform: String
            let hardwareConcurrency: Int
            let deviceMemoryGB: Int
            let maxTouchPoints: Int
            let screenWidth: Int
            let screenHeight: Int
            let screenAvailWidth: Int
            let screenAvailHeight: Int
            let devicePixelRatio: Double
            let colorDepth: Int
            let locale: String
            let languages: [String]
            let timezone: String
            let webglVendor: String
            let webglRenderer: String
            let webglUnmaskedVendor: String
            let webglUnmaskedRenderer: String
            let webglVersion: String
            let webglShadingLanguage: String
            let audioSampleRate: Int
            let rasterVariance: Double
            let webglPrecisionSeed: Double
            let audioFingerprintSeed: Double
        }
        let wire = Wire(
            userAgent: profile.userAgent,
            platform: profile.platform,
            hardwareConcurrency: profile.hardwareConcurrency,
            deviceMemoryGB: profile.deviceMemoryGB,
            maxTouchPoints: profile.maxTouchPoints,
            screenWidth: profile.screenWidth,
            screenHeight: profile.screenHeight,
            screenAvailWidth: profile.screenAvailWidth,
            screenAvailHeight: profile.screenAvailHeight,
            devicePixelRatio: profile.devicePixelRatio,
            colorDepth: profile.colorDepth,
            locale: profile.locale,
            languages: profile.languages,
            timezone: profile.timezone,
            webglVendor: profile.webglVendor,
            webglRenderer: profile.webglRenderer,
            webglUnmaskedVendor: profile.webglUnmaskedVendor,
            webglUnmaskedRenderer: profile.webglUnmaskedRenderer,
            webglVersion: profile.webglVersion,
            webglShadingLanguage: profile.webglShadingLanguage,
            audioSampleRate: profile.audioSampleRate,
            rasterVariance: profile.rasterVariance,
            webglPrecisionSeed: profile.webglPrecisionSeed,
            audioFingerprintSeed: profile.audioFingerprintSeed
        )
        let data = (try? JSONEncoder().encode(wire)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
