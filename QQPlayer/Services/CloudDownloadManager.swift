//
//  CloudDownloadManager.swift
//  QQPlayer
//
//  ⚠️ M3-2 退役（2026-09-10）：iOS 音乐存储已切本地沙盒 Documents，iCloud ubiquity
//  下载链路（dataless 实体化/NSMetadataQuery 进度监控/系统性失败切换离线）整体退役。
//  播放路径的 ensureLocal 调用已改本地文件可读检查；本文件已无引用。
//  物理删除留 maintainer squash 时定夺（QQPlayer/ 目录 filesystem-synced 到
//  iOS target，tombstone 空文件即可编译，删文件需动 membershipExceptions）。
//
