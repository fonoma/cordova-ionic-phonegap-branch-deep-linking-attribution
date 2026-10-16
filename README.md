## Branch SDK Documentation for Cordova PhoneGap Ionic

View [Branch's SDK documentation for Cordova PhoneGap Ionic](https://help.branch.io/developers-hub/docs/cordova-phonegap-ionic)

## Changes compared with master

This branch improves session reinitialization and deep-link resolution on iOS and Android, including links opened while the app is running and Branch URLs received by notification click handlers.

| Area | On `master` | In this branch |
| --- | --- | --- |
| Forced sessions | `forceNewSession()` is exposed in JavaScript and implemented on Android only. | Adds the iOS implementation and accepts an optional absolute URL on both platforms. |
| Session coordination | Android starts forced sessions directly. | Queues forced requests behind pending initialization and earlier forced requests, with separate callbacks and timeout handling. |
| Link replay | Android forced sessions read the current activity intent. | Retains original native and notification URLs and recovers deferred links for later replay. |
| Native link routing | Incoming links follow native Branch handling, with no JavaScript routing configuration or link-open event. | Adds opt-in `setNativeLinkHandling({ scheme, domains })` and the `branch:linkOpened` event. |
| iOS URL forwarding | URLs forwarded through Cordova notifications are passed to Branch again by the plugin. | Marks URLs already processed by the delegate to avoid duplicate processing. |
| iOS push notifications | Notification receipts are forwarded directly to Branch. | When native routing is enabled, the notification click handler owns resolving the Branch URL. |

### Forced sessions on iOS and Android

`Branch.forceNewSession(url)` resolves a new session using a supplied absolute URL. This extends the existing no-argument API on `master` and makes it available on iOS as well as Android. HTTP(S) and custom scheme URLs are supported; invalid URLs and URLs containing whitespace reject the Promise.

The no-argument form, `Branch.forceNewSession()`, remains supported. It reuses the latest captured or explicitly supplied URL. If no URL is known, it requests a session without a URL. Repeated calls for the same URL are supported, and each call returns its own Promise with the resolved Branch parameters.

Compared with the direct Android reinitialization in `master`, forced calls now retain their own URL and callback while waiting in order. Android waits for pending initialization before processing forced requests. iOS queues initialization and forced requests together and matches forced-session responses to the corresponding request. Errors, exceptions, and session timeouts release the queue, while late or duplicate callbacks are guarded against completing an already finished request.

Successful calls resolve to a parameters object, or `{}` when no parameters are returned. Timeout budgets are derived from the native SDK's network and retry settings.

### Retaining links for replay

The branch preserves URLs before native SDK processing can consume or alter them. On Android, this includes the activity intent and the notification's `branch` extra, retaining custom scheme parameters such as `link_click_id`. On iOS, the app delegate can retain an incoming URL even before the Cordova plugin initializes.

Deferred links returned in `~referring_link` can also supply a URL for queued forced requests made before a link was known. Explicitly supplied URLs and already captured URLs remain associated with their own requests. This improves replay of existing deep-link flows; deep-link and deferred attribution support already exist on `master`.

### Opt-in native link routing

`Branch.setNativeLinkHandling({ scheme, domains })` is new in this branch. It lets your JavaScript handler own resolution of matching native opens through `Branch.forceNewSession(url)`.

- `scheme` is the URI scheme name, without `:` or `://`.
- `domains` contains bare HTTP(S) hostnames, without protocols, ports, paths, or wildcards. List alternate domains and subdomains explicitly; an empty array enables only the configured scheme.
- Scheme and host matching are case-insensitive, and hosts must match exactly.

Register a `branch:linkOpened` listener on `document` **before** enabling this mode. The event carries the incoming URL in `event.detail.url`, rather than resolved Branch parameters. In opt-in mode, the listener must call `forceNewSession` to resolve that URL.

For example, after replacing the scheme and domains with your app's configuration:

```javascript
document.addEventListener("deviceready", async function () {
  function handleParams(params) {
    console.log("Branch session parameters", params);
    // Navigate using the resolved parameters.
  }

  document.addEventListener("branch:linkOpened", function (event) {
    Branch.forceNewSession(event.detail.url)
      .then(handleParams)
      .catch(console.error);
  });

  try {
    await Branch.setNativeLinkHandling({
      scheme: "myapp",
      domains: ["example.app.link", "example-alternate.app.link"]
    });
    handleParams(await Branch.initSession());
  } catch (error) {
    console.error("Branch setup failed", error);
  }
}, false);
```

Existing native handling remains the default until this mode is enabled. Link-open events are also emitted in the default mode, where the native SDK may already be processing the URL; account for that before forcing another session. In opt-in mode, unmatched links remain available to other integrations. On iOS, unmatched custom scheme URLs are forwarded through Cordova's URL notification, and unmatched URLs are reported through `BSDKPostUnhandledURL`.

### Notification clicks and lifecycle behavior

A push SDK click handler, including OneSignal's, can pass its Branch URL directly to `Branch.forceNewSession(url)`. On Android, this works even when the notification does not deliver a new activity intent. Coordinate the click handler and native link-open listener so that the same open is resolved once.

On iOS, `master` forwards notification receipts to Branch. With native routing enabled in this branch, that forwarding is skipped: the click handler should resolve the URL when the user opens the notification.

Continue to call `Branch.initSession()` after `deviceready` for startup and deferred-link parameters. Link-open events require an active WebView and listener and are not buffered for listeners registered later. Runtime routing configuration is cleared when the WebView resets, so register the listener and configure the mode again when JavaScript initializes after a reset. iOS also invalidates pending session work on reset or disposal.

The routing options select which incoming links JavaScript resolves. They do not replace the platform configuration for URL schemes, iOS Universal Links, or Android App Links, and they do not restrict explicit calls to `forceNewSession(url)`.

