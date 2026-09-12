# Fixtures（未注册到任何 target 的音频夹具 —— 见下）

> 状态：**未被任何 target 引用**，保留仅为溯源。审计 2026-09-12（⚰️ 死代码）记录：
> 这三个文件既不进 bundle，也没有任何测试引用它们。

- `smoke-empty.mp3`（2023 B）、`smoke-empty.flac`（11876 B）、`smoke-empty.m4a`（3773 B）

## 为什么它们没被用到

测试实际用的是 **base64 内嵌夹具**，不是磁盘文件：

- `QQPlayerTests/TestAudioFixtures.swift:15` `enum TestAudioFixtures`（内嵌 base64 + 注释记录生成命令）
- 调用点：`QQPlayerTests/GenreParsingTests.swift:70-72`、`TagWriterTests.swift:26-28`
  （`writeFixture(…, base64:)`）

QQPlayerTests target 的 Resources phase 为空，所以即使放到这里也不会进测试包。

## 生成方式（如需重建同款夹具）

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.3" -c:a libmp3lame -q:a 9 -write_id3v2 0 smoke-empty.mp3
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.3" -c:a flac smoke-empty.flac
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.3" -c:a aac -f ipod smoke-empty.m4a
```

## 处置

删除这三个文件属「清理死代码」，但按子代理守则 §6 红线（不得删除文件），
本批次**只登记不删除**，等 maintainer 决定是否清理。删除前请先确认：

```bash
grep -rn "smoke-empty" QQPlayerTests/ QQPlayer.xcodeproj/project.pbxproj
```

（当前唯一命中是内嵌 base64 的注释与调用名，均不依赖本目录的磁盘文件。）
