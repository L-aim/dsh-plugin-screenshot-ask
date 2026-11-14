window.__ModuleLoader__.load({
  id: "dsh-plugin-screenshot-ask",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;

    // client 半边可用的服务由 dsh-client-* 包提供；这里只用 commandUi（"+ 面板/斜杠命令"）。
    const inject = ["commandUi"];

    /**
     * 把一张 PNG dataURL 作为「用户拖进来的文件」塞进当前会话输入框。
     *
     * 原理：ui-attachment 的 installDocumentDropEvents 在 document 上挂了 dragover/drop
     * 监听，且只看 dataTransfer.types 是否含 "Files"，然后把 dataTransfer.files 交给
     * onAddFiles —— 也就是「拖拽上传」那条真实链路。所以我们构造一个真的 DragEvent
     * 派发到页面里，附件缩略图与后续上传都走原生逻辑，不依赖任何未公开 API。
     */
    function deliverImageAsDrop(dataUrl, name) {
      const comma = String(dataUrl).indexOf(",");
      if (comma < 0) throw new Error("not a data URL");
      const header = dataUrl.slice(0, comma);
      const mediaType = (header.match(/^data:([^;]+)/) || [, "image/png"])[1];
      const binary = atob(dataUrl.slice(comma + 1));
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

      const file = new File([bytes], name || "screenshot.png", { type: mediaType });
      const dataTransfer = new DataTransfer();
      dataTransfer.items.add(file);

      const target =
        document.querySelector('[contenteditable="true"]') ||
        document.querySelector("textarea") ||
        document.body;

      for (const type of ["dragenter", "drop"]) {
        target.dispatchEvent(
          new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer })
        );
      }

      // 让焦点回到输入框，用户可以直接补问题
      if (target && typeof target.focus === "function") {
        try {
          target.focus();
        } catch {}
      }
      return { bytes: bytes.length, mediaType, target: target.tagName };
    }

    /** 调宿主截图路由；返回宿主给的 JSON，失败抛 Error（message 直接给用户看）。 */
    async function callHost(route) {
      const response = await fetch(route, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
        credentials: "same-origin",
      });
      let payload = null;
      try {
        payload = await response.json();
      } catch {
        payload = null;
      }
      if (!response.ok || !payload) {
        const message =
          (payload && (payload.message || payload.code)) || "HTTP " + response.status;
        throw new Error(message);
      }
      return payload;
    }

    const kb = (bytes) => Math.round(bytes / 1024) + " KB";

    function apply(ctx) {
      ctx.inject(["commandUi"], (scope) => {
        const command = scope.get("commandUi");

        scope.effect(
          () =>
            command.register({
              name: "screenshot-ask-capture",
              // label/description 必须是函数：传字符串会让整份候选列表一起失败
              label: () => "截图提问",
              description: () => "框选屏幕上一块区域，图片直接放进输入框，补个问题就能发",
              available: () => true,
              ui: {
                kind: "action",
                run: async () => {
                  try {
                    const shot = await callHost("/api/screenshot-ask/capture-region");
                    if (shot && shot.copied) {
                      return { kind: "success", text: "已复制到剪贴板，没有放进输入框" };
                    }
                    if (shot && shot.cancelled) {
                      return { kind: "success", text: "已取消，没有截图" };
                    }
                    const placed = deliverImageAsDrop(shot.dataUrl, shot.name);
                    return {
                      kind: "success",
                      text:
                        "已截取 " +
                        shot.width +
                        "×" +
                        shot.height +
                        "（" +
                        kb(placed.bytes) +
                        "），补个问题就能发",
                    };
                  } catch (error) {
                    return {
                      kind: "success",
                      text:
                        "⚠️ 截图失败：" + (error && error.message ? error.message : String(error)),
                    };
                  }
                },
              },
            }),
          "screenshot-ask: 截图提问命令"
        );
      });
    }

    exports.apply = apply;
    exports.inject = inject;
    return module.exports;
  },
});
