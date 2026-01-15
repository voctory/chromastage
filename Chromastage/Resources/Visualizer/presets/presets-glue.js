(function () {
  const baseModule = self.base;
  const extraModule = self.extra;
  const basePresets = baseModule ? (baseModule.default || baseModule) : {};
  const extraPresets = extraModule ? (extraModule.default || extraModule) : {};

  self.butterchurnPresets = {
    getPresets() {
      return { ...basePresets, ...extraPresets };
    },
  };
})();
