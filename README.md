# spf13-vim Windows 离线部署包

这个文件夹包含当前电脑上的 spf13-vim 配置、全部插件、个人配置，以及 Vim 8.1（32 位）运行环境。插件和 Vim 运行时的数千个小文件已经封装在单个 `payload.zip` 中，以加快 GitHub 下载包的解压和电脑间复制；4 个可维护配置保留在 `config` 目录中。

## 在另一台 Windows 电脑上安装

1. 将整个 `spfvim13` 文件夹复制到目标电脑，不能只复制 `install.bat`。
2. 双击运行 `install.bat`。
3. 等待 `payload.zip` 完整性校验、解包和部署结束。
4. 如果安装程序提示已添加 PATH，请关闭并重新打开命令提示符或 PowerShell。
5. 输入 `vim`，或运行 Vim/gVim。

安装不需要管理员权限。

Caps Lock→左 Ctrl 是包内可选功能，并且默认安装。若不需要，直接双击 `install-no-caps.bat`；也可以在 PowerShell 中运行：

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -SkipCapsCtrl`

## 安装程序会做什么

- 校验 `payload.zip`，发现下载或复制损坏时会停止。
- 在可恢复的临时目录中展开配置、插件和 Vim 文件。
- 将 spf13-vim 配置部署到当前用户目录。
- 将插件部署到 `%USERPROFILE%\.vim`。
- 默认安装一个很小的 Caps→Ctrl 助手；它只接受 `vim.exe`/`gvim.exe`，并随对应 Vim 退出。
- 在 ConEmu 中运行 `vim.exe` 时，映射只在启动 Vim 的 ConEmu 窗口位于前台时生效；切走后立即恢复 Caps Lock。
- 如果电脑已有 Vim，就继续使用已有 Vim。
- 如果没有检测到 Vim，就把随包附带的 Vim 安装到：
  `%LOCALAPPDATA%\Programs\spf13-vim\vim81`
- 安装附带 Vim 时，会把该目录加入当前用户的 PATH。
- 部署完成后执行一次静默启动检查。

## 中文编码兼容（Windows 10/11）

- Vim 内部和新建文件统一使用 UTF-8。
- 打开已有文件时会自动识别 UTF-8、带 BOM 的 UTF-16、GB18030、GBK/CP936 和 Big5。
- 不再把 Windows 终端编码固定为西欧 `cp850`，可适配中文或英文版 Windows 10/11、Windows Terminal、Git Bash 和传统控制台。
- 空白符和状态栏使用 ASCII 字符，避免部分字体或 `ambiwidth=double` 环境触发 `E474: Invalid argument: listchars`。
- gVim 会从新宋体、宋体、微软雅黑中选择目标电脑可用的中文字体。

如果文字显示成方框而不是乱码，表示目标电脑缺少中文字体。请在 Windows“可选功能”中安装中文补充字体，或使用支持中文字体的 Windows Terminal/gVim。

## 安装被中断时

安装程序采用“先暂存、后切换”的方式：

- 在校验和解包暂存文件期间，原有 Vim 配置不会被改动。
- 正式切换前会写入恢复记录，再备份旧配置。
- 如果断电、强制关机、误关窗口或进程被终止，直接再次运行 `install.bat`。
- 下次运行会识别未完成的事务，自动清理未完成的暂存文件，或恢复中断前的旧配置，然后重新安装。
- 同一用户不能同时运行两个安装程序，避免互相覆盖。
- Caps→Ctrl 助手也由同一事务部署；安装中断时不会留下半成品。

安装期间请保留足够空间。因为会先暂存完整插件，建议目标电脑的用户目录所在磁盘至少有 500 MB 可用空间；如果电脑已经存在一套较大的 Vim 插件，建议预留更多空间用于备份。

## 旧配置备份

如果目标电脑已经有 Vim 配置，安装程序不会直接删除它们，而是先移动到：

`%USERPROFILE%\spf13-vim-backups\日期-时间`

备份可能包括：

- `_vimrc`
- `.vimrc`
- `.vimrc.before`
- `.vimrc.bundles`
- `.vimrc.local`
- `.vim`

需要恢复时，先关闭 Vim，再将相应备份文件复制回用户目录。

## 注意事项

- 这是当前环境的离线快照，插件不会在安装时访问网络。
- 包内 Vim 为当前电脑使用的 Vim 8.1 32 位版本。目标电脑已有较新 Vim 时，安装程序不会覆盖它。
- 不要修改或删除 `payload.zip`、`manifest.sha256`、`install.ps1`。
- Caps→Ctrl 不修改注册表或全局键盘映射；支持 Windows 10/11、gVim 以及 ConEmu 中的 Vim，切换到其他应用后 Caps Lock 保持原功能。
