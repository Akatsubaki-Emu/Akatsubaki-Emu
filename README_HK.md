# Akatsubaki Emu — 香港版使用指南（繁體中文）

> [English project README](README.md) · [日本語ガイド](README_JP.md)

本頁為香港使用者整理 Akatsubaki Emu 的下載、安裝、測試及回報問題方法。這是地區化的入門指南；香港地區並沒有獨立的程式版本或特殊功能保證。

## 重要聲明

Akatsubaki Emu 仍在積極開發，屬於實驗性軟件，可能不穩定、當機或遺失資料。請勿把重要資料或唯一副本放在測試環境中。使用者須自行承擔測試風險。

**目前它並不是可完整運行 Windows／Linux 遊戲的 PC 模擬器。** 成功下載、簽署或安裝 IPA，並不代表客體作業系統或遊戲能夠啟動。

## 專案目前狀態

- 主要目標：iOS／iPadOS；另有早期 tvOS 及 visionOS 目標。
- Kenran Butō（絢爛舞踏）混合執行核心正在開發，包含有限範圍的 x86-64 解譯及 ARM64 AOT 實驗。
- 部分靜態 Linux x86-64 ELF 測試程式可在主機測試環境執行；這不代表完整 Linux 桌面或一般應用程式已可運行。
- 完整 Windows 執行環境、Wine／Proton、動態連結、3D GPU 翻譯、完整客體輸入／網絡及遊戲相容性尚未獲確認。
- QEMU／UTM 全系統執行路徑仍受第三方授權審查及發佈閘門限制。
- 尚未確認在實體 iPhone／iPad 上成功啟動完整客體作業系統。

請以主專案 README、發佈說明及測試紀錄為準；不要把規劃中的功能當成已完成的功能。

## 下載

只使用官方專案連結：

- [GitHub 專案](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu)
- [所有正式發佈及測試版本](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases)
- [Nightly 測試版本](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/nightly)
- [Main 發佈版本](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/main)
- [官方 AltStore／PAL source](https://akatsubaki-emu.github.io/AltSource.json)

下載時請選擇與裝置相符的 iOS IPA。tvOS 套件並不適用於 iPhone／iPad。Nightly 包含較新的開發變更，可能較不穩定。

## 在 iPhone 或 iPad 安裝

1. 從官方 Releases 或成功的 GitHub Actions 發佈工作下載 iOS IPA。
2. 如發佈附有 SHA-256 checksum，可下載相應 checksum 檔案核對同一個 IPA。
3. 使用支援該 IPA 的簽署／側載工具，例如 [SideStore](https://sidestore.io/)。
4. 按照 [SideStore 官方文件](https://docs.sidestore.io/)完成設定、匯入、簽署及安裝。
5. 若簽署或刷新失敗，先查看簽署工具的錯誤及官方疑難排解文件，再提交問題。

**IPA 是未簽署的測試套件。** 單純把 IPA 儲存在「檔案」App 並不會安裝它。簽署資格、重新整理限制及裝置配對狀態取決於 Apple 帳戶、裝置和所用工具；香港 Apple 帳戶不會自動解除 iOS 的簽署或 JIT 限制。

## 香港使用者注意事項

- 下載及安裝方式與其他地區相同；目前沒有獨立的香港版 IPA。
- 不需要因為這份指南而更改 Apple 帳戶國家／地區。請勿為了側載而隨意更改帳戶地區。
- 網絡供應商、DNS、公司／校園網絡或下載服務的可用性可能影響下載；這不代表專案提供香港專用鏡像。
- JIT、記憶體權限及背景執行能力由 iOS 版本、裝置、簽署方式、entitlements 和支援工具共同決定，並非單靠所在地區設定即可啟用。
- 使用者應自行確認所匯入的 BIOS、韌體、作業系統映像、遊戲及其他檔案具有合法使用權。請勿分享未獲授權的遊戲或系統映像。
- 本文件不是香港法律、版權或 Apple 帳戶支援意見；如涉及權利或合規問題，請查閱適用的官方資料或尋求合資格意見。

## 回報問題

提交問題時，請盡量附上：

- iPhone／iPad 型號，以及 iOS／iPadOS 版本；
- Akatsubaki Emu 版本、commit 或發佈連結；
- 安裝工具及其版本；
- 重現步驟、預期結果和實際結果；
- 完整錯誤訊息、相關 build log 或 crash log。

分享紀錄前，請遮蓋 Apple ID、驗證碼、存取權杖、私人網址、憑證、私鑰及其他個人資料。

## 相關連結

- [完整安裝指南（英文）](INSTALL.md)
- [專案文件及架構](https://akatsubaki-emu.github.io/docs/)
- [Kenran Butō 混合執行架構](docs/HYBRID_RUNTIME_ARCHITECTURE.md)
- [首次可玩 iOS 版本驗收清單](docs/FIRST_PLAYABLE_IOS_ACCEPTANCE.md)
- [第三方授權聲明](THIRD_PARTY_NOTICES.md)
- [回報問題及貢獻指南](CONTRIBUTING.md)

## 授權

Akatsubaki Emu 由專案作者編寫的檔案採用 GPL-3.0-or-later；第三方元件仍受其各自授權條款約束。詳情請參閱 [LICENSE](LICENSE)、[REUSE/DEP5](.reuse/dep5) 及 [第三方聲明](THIRD_PARTY_NOTICES.md)。
