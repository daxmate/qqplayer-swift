# 更新日志

本文件记录 QQPlayer 的版本变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.4] - 2026-11-11

### 🐛 修复

- 修复 Mac → iPhone 同步在 iPhone 退后台重连后必然超时：Mac 同步宿主会保留半开的旧会话占位，导致 iPhone 重连时新会话被丢弃。现在宿主会让旧会话正确让位，退后台再回来即可正常完成同步。

[1.1.4]: https://github.com/daxmate/qqplayer-swift/compare/5ac27aa...v1.1.4
