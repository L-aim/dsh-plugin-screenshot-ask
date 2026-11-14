# 截图提问 · dsh-plugin-screenshot-ask

给 DeepSeek Harness 的截图插件：点一下，框选屏幕上任意一块区域，截图**直接出现在输入框里**
（不再是「先存文件、再拖进来」），补一句话就能发。

> 只支持 Windows（依赖 PowerShell 5.1 + WPF）。

## 用起来是什么样

1. 输入框左下角点 `+`，在「指令」组里点 **截图提问**；
2. 屏幕变暗、DSH 自动让开，拖出一块区域；
3. 松手后还能调：拖八个把手改大小、拖框内移动位置，工具条上显示 `宽 × 高`（物理像素）；
4. `确认`（或 Enter）→ 图片进输入框；`复制` → 只进剪贴板；`取消`（或 Esc / 右键）→ 什么都不做；
5. 在输入框里补问题，发送。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | Windows 10 / 11 |
| PowerShell | 5.1（脚本自带 `-ExecutionPolicy Bypass`，不用改系统策略） |
| DSH | 带 Web UI 的版本（用到 `commands` / `webServer` 两个服务） |
| Node | ≥ 20（插件是纯 ES module，无构建步骤） |

## 安装

把仓库目录（含 `package.json` 的那一层）装进当前 profile：

```
plugin_manager install_bundle  <本仓库绝对路径>
```

装完会往 profile 里加一条 `dsh-plugin-screenshot-ask`。改完代码不必重装，重载一次即可：

```
plugin_manager set_bundle  target=dsh-plugin-screenshot-ask  enabled=false
plugin_manager set_bundle  target=dsh-plugin-screenshot-ask  enabled=true
```

然后刷新页面（Ctrl+R），`+` 菜单里就有「截图提问」了。

## 它怎么工作

```
点击命令 ──▶ 页面 POST /api/screenshot-ask/capture-region
              │
              ▼
       宿主 index.js ── 写一行 JSON 进常驻进程 stdin
              │
              ▼
   lib/server.ps1（常驻，WPF 只装载一次）
     隐藏 DSH 窗口 → 抓全屏静帧 → 弹覆盖层拖框/微调 → 裁切 → PNG base64
              │
              ▼
       宿主包成 data:image/png;base64,… 返回页面
              │
              ▼
   lib/client.js 造一个 DataTransfer + drop 事件派发到输入框
              │
              ▼
       原生附件链路：缩略图 → 上传 → 发送（与手动拖图完全一致）
```

两个关键取舍：

- **不碰未公开 API**：图片进输入框靠的是「模拟一次拖放」。`ui-attachment` 在 `document` 上
  监听 `drop`，只看 `dataTransfer.types` 是否含 `Files`，所以页面里自己造事件就够了，
  缩略图、上传、发送全走原生链路。
- **为什么截图时 DSH 要消失几十毫秒**：静帧里不能有 DSH 自己。本想让窗口对截图「透明」
  （`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`），实测无效——该 API 只对调用进程
  自己的窗口生效，跨进程调用直接返回 false。所以只能 隐藏 → 抓图 → 恢复。

顺带一个坑：DSH 是 Electron 多进程，可见窗口属于主进程而插件宿主只是它的子进程，所以窗口是按
**进程族**找的；族里还有 Chromium 的隐藏辅助窗口（`Chrome_WidgetWin_0`），那些本来不可见的
窗口一律不碰——曾经把它们一起 `ShowWindow`，结果误显示成一块纯黑矩形。

## 目录结构

| 文件 | 角色 |
| --- | --- |
| `index.js` | 宿主半边：两条 `webServer` 路由 + 常驻子进程管理（stdin/stdout 一行一 JSON） |
| `lib/server.ps1` | 常驻进程：抓屏、圈选覆盖层、裁切、PNG 编码 |
| `lib/client.js` | 页面半边：注册命令行 + 把 base64 变成真的 `File` 塞进输入框 |
| `cordis.patch.yml` | bundle patch：往组合里插入 `id: screenshot-ask` |

## 性能（2560×1600 @150%）

| 操作 | 耗时 |
| --- | --- |
| 首次点击（起进程 + 预热 .NET/WPF） | ~1.6 s |
| 之后每次框选 | 260–500 ms |
| 抓整屏不弹覆盖层（调试路由） | ~370 ms |

## 已知限制

- 只有矩形圈选，没有椭圆、贴边吸附、滚动截屏、标注。
- 截图瞬间 DSH 会消失约 60–200 ms（先把它从画面里拿掉）。
- 多显示器按虚拟屏整体做底图；各屏缩放比例不同时，选区可能差几个像素。
- 同一时刻只允许一次圈选，重复点击返回 `code: busy`。
- 覆盖层 180 s 无操作会自动取消，避免屏幕一直被盖住。

## 排错

- 日志：`%TEMP%\dsh-plugin-screenshot-ask.log`
  （`server warm (pid …)` / `hide settle: …ms (1 window(s), K invisible skipped)` /
  `region: 宽x高, 字节, 耗时` / `region: 用户取消`）。
- 直接跟常驻进程对话（一行一条 JSON）：

  ```
  printf '{"id":1,"op":"ping"}\n{"id":2,"op":"crop","rect":"100,100,400,300"}\n' | powershell -NoProfile -ExecutionPolicy Bypass -File lib\server.ps1
  ```

- 看它到底认了哪个窗口：发 `{"id":1,"op":"windows"}`，返回识别到的进程族与窗口矩形。
- 验证「隐藏真的改变了画面」：同一矩形分别用 `{"id":1,"op":"crop","rect":"x,y,w,h","nohide":true}`
  与不带 `nohide` 各抓一张，两张图必须显著不同——一样就说明窗口没被藏掉。

## 许可证

见 [LICENSE](LICENSE)。
