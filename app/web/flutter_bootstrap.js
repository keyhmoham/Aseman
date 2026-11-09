{{flutter_js}}
{{flutter_build_config}}

// Optimized loader: CanvasKit "auto" picks the smaller chromium variant when
// safe; entrypoint + engine start without a legacy service worker.
_flutter.loader.load({
  config: {
    canvasKitVariant: "auto",
  },
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      canvasKitVariant: "auto",
    });
    await appRunner.runApp();
  },
});
