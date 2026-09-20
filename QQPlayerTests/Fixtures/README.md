# Fixtures

本目录两类东西：

- **棘轮基线**（`*-baseline.tsv` / `*-baseline.sha256` / `budget-plan.md`）—— 各契约测试的存量清单，**只减不增**，改生产必须同步改基线（见各 `*ContractTests.swift` 文件头）。
- **无 target 归属的音频夹具**（原 `smoke-empty.{mp3,flac,m4a}`）—— 见下。

## 已清理：`smoke-empty.{mp3,flac,m4a}`（2026-09-20，测试债批 ⑤）

**处置：删除（走 `trash`，可恢复）。** 依据（2026-09-19 测试审计 `1-useless-assertions.md` P3-9，
本 README 原「只登记不删除」段落的升级）：

- 全仓**无任何读取点**：QQPlayerTests target 的 Resources phase 为空，这三个文件不进测试包；
  唯一的同名引用是**内嵌 base64 夹具**的**名字**（`GenreParsingTests.swift:70-72` 的用例名 +
  `TestAudioFixtures.swift` 的生成命令注释 + 字节数注释），不依赖本目录的磁盘文件。
- 删除前复核：`grep -rn "smoke-empty" QQPlayerTests/ QQPlayer.xcodeproj/project.pbxproj`
  → 命中全是名字/注释，pbxproj 零引用（无注册项可清）。

**现在测试用的夹具在哪**：`QQPlayerTests/TestAudioFixtures.swift`（内嵌 base64，唯一来源）。
需要重建同款磁盘文件时，生成命令（对应 mp3 2023 B / flac 11876 B / m4a 3773 B）：

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.3" -c:a libmp3lame -q:a 9 -write_id3v2 0 smoke-empty.mp3
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.3" -c:a flac smoke-empty.flac
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.3" -c:a aac -f ipod smoke-empty.m4a
```
