# R115 桌面启动入口

源码位于权威仓库 `sw/rv64/r115-desktop/`。当前分支为 `research/rv64`，HEAD 为 `5316c60`；工作树存在此前多阶段未提交文件，不能把 HEAD 当作本轮全部源码的版本。

`desktop-session-r1.sh` 只在已经准备好的 Debian 只读 SquashFS + RAM overlay chroot 中使用。它不负责板卡复位、装载、挂载或写入启动介质。依赖当前已核验的官方 Debian 包集合、DRM card0、两个 input event 节点及原 `/usr/local/libexec/rv64-openbox-session`。

已有图形会话时，它会返回 73，保留当前 Xorg、窗口和 Shell。这一分支已在真实自研 CPU 上执行并通过，目标脚本 SHA256 为 `d573d20f242bd5dc5a1d09b72d8746f0c7a0aafa3cf0244fa76df1212f3ff310`。目标 BusyBox `sh -n` 通过。

在没有图形会话、但挂载仍存在时，本轮实际命令等价于：

```sh
b=/bin/busybox
r=/tmp/r114desk1/root
$b setsid $b chroot "$r" $b sh /tmp/r115-session.sh \
  >/tmp/r114desk1/r115-session1.log 2>&1 &
```

脚本必须先放入 chroot 内 `/tmp/r115-session.sh`；此目录属于 RAM。本轮使用逐命令不超过 60 UTF-8 字节的压缩上传，解包后在板上核验 SHA256。不要把这组路径当成重新上电后自动存在的文件。

脚本组合以下已实际手工验证的配置：三个 X core font、两个 DejaVu UI 字体、局部 fontconfig、禁用 GLX、modesetting 软件渲染、自动添加 libinput 设备、udevd/input coldplug、单工作区、关闭背景普通滚轮切换、最小 Terminal 菜单。日志中 `RV64_DESKTOP_STAGE` 使用目标 `/proc/uptime` 记录 prepare、udev 和 xorg 阶段。

`one-workspace-r1.py` 是已经实际执行的当前会话恢复工具：通过现有 Python ctypes 和 libX11 发送标准 EWMH 请求，不伪造根窗口属性，不生成键鼠事件，不销毁窗口。请求完成后由独立 `obxprop` 读回确认一个桌面、当前索引 0、原终端 WM_STATE=1；用户进一步确认滚轮后窗口保持可见、`echo input_ok` 成功。它首次加载 Python/ctypes 较慢，不是常规桌面启动的依赖。

本轮新入口完整启动验证进行中，不能用语法或重复启动保护测试代替完整桌面重启通过，也不是独立 Linux 重启。最终验证结果另存，不回写此前快照。
