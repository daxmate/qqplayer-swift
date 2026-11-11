# 更新日志

本文件记录 QQPlayer 的版本变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.5] - 2026-11-11

### 🚀 性能

- 局域网同步支持文件级并发：一次最多同时传输 4 个文件（每个文件保留 8 块滑动窗口），全局在途字节上限 24MB；对端为旧版本时自动退回串行传输，行为不变。批量同步多首歌曲时总耗时明显下降。

[1.1.5]: https://github.com/daxmate/qqplayer-swift/compare/v1.1.4...v1.1.5

## [1.1.4] - 2026-11-11

### 🐛 修复

- 修复 Mac → iPhone 同步在 iPhone 退后台重连后必然超时：Mac 同步宿主会保留半开的旧会话占位，导致 iPhone 重连时新会话被丢弃。现在宿主会让旧会话正确让位，退后台再回来即可正常完成同步。

[1.1.4]: https://github.com/daxmate/qqplayer-swift/compare/5ac27aa...v1.1.4
