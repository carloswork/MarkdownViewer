// Custom bootstrap template. Flutter substitutes the {{...}} tokens at build time.
//
// canvasKitBaseUrl is pinned to the locally bundled copy. `flutter build web
// --no-web-resources-cdn` already does this, but flutter.js still carries the
// gstatic URL as a fallback string and there is a history of the flag being
// ignored across releases (flutter/flutter#148713). Setting it explicitly means
// the CDN path cannot be taken even if the flag regresses. The URL is relative,
// so it resolves against <base href> and works under a GitHub Pages sub-path.
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
  },
});
