# Akatsubaki Emu — 日本語ガイド

> [English project README](README.md) · [香港繁體中文ガイド](README_HK.md)

このページでは、日本の利用者向けに Akatsubaki Emu のダウンロード、インストール、テスト、問題報告の手順を説明します。地域向けの案内であり、日本専用ビルドや日本での動作保証を意味するものではありません。

## 重要なお知らせ

Akatsubaki Emu は開発中の実験的なソフトウェアです。不安定な動作、クラッシュ、データ消失が発生する可能性があります。重要なデータや唯一のコピーをテスト環境に置かないでください。利用・テストは自己責任で行ってください。

**現時点で、Windows／Linux のゲームを完全に実行できる PC エミュレーターではありません。** IPA のダウンロード、署名、インストールが成功しても、ゲスト OS やゲームが起動するとは限りません。

## 現在の開発状況

- 主な対象は iOS／iPadOS です。tvOS と visionOS のターゲットも初期段階にあります。
- ハイブリッド実行コア **Kenran Butō（絢爛舞踏）** を開発中です。限定的な x86-64 インタープリターと ARM64 AOT 変換の実装・検証が進められています。
- 一部の静的 Linux x86-64 ELF テストプログラムはホスト側のテスト環境で実行できます。一般的な Linux アプリやデスクトップ環境が動作するという意味ではありません。
- 完全な Windows 実行環境、Wine／Proton、動的リンク、3D GPU 変換、完全なゲスト入力・ネットワーク、ゲーム互換性は確認されていません。
- QEMU／UTM によるフルシステム実行経路は、サードパーティのライセンス確認と配布承認の対象です。
- 実機 iPhone／iPad でゲスト OS の起動が完了したことは、まだ確認されていません。

機能の実装状況は、メイン README、リリース情報、テスト記録を確認してください。予定や試作段階の機能を完成済みとして扱わないでください。

## ダウンロード

公式リンクのみを使用してください。

- [GitHub リポジトリ](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu)
- [すべてのリリース／テストビルド](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases)
- [Nightly テストビルド](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/nightly)
- [Main リリース](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/main)
- [公式 AltStore／PAL ソース](https://akatsubaki-emu.github.io/AltSource.json)

iPhone／iPad では iOS 用 IPA を選択してください。tvOS 用パッケージは iPhone／iPad には使用できません。Nightly は新しい開発変更を含むため、より不安定な場合があります。

## iPhone／iPad へのインストール

1. 公式 Releases、または成功した GitHub Actions リリースワークフローから iOS IPA をダウンロードします。
2. SHA-256 チェックサムが公開されている場合は、同じ IPA に対応するファイルを使って整合性を確認します。
3. [SideStore](https://sidestore.io/) など、その IPA に対応する署名・サイドロードツールを用意します。
4. [SideStore 公式ドキュメント](https://docs.sidestore.io/)に従って、初期設定、IPA の読み込み、署名、インストールを行います。
5. 署名や更新に失敗した場合は、使用しているツールのエラーと公式トラブルシューティングを先に確認してください。

配布される IPA は**未署名のテスト用パッケージ**です。「ファイル」アプリに保存しただけではインストールされません。署名の可否、更新制限、デバイスのペアリングは Apple アカウント、端末、使用するツールによって異なります。日本の Apple アカウントであっても、iOS の署名制限や JIT 制限が自動的に解除されるわけではありません。

## 日本の利用者向けの注意

- インストール手順は基本的に他地域と同じです。現在、日本専用 IPA はありません。
- このガイドを理由に Apple アカウントの国／地域を変更する必要はありません。サイドロード目的で安易にアカウント地域を変更しないでください。
- 通信事業者、DNS、学校・職場のネットワーク、配布サービスの状態によってダウンロードできない場合があります。日本専用ミラーの提供を意味するものではありません。
- JIT、メモリ権限、バックグラウンド実行の可否は、iOS バージョン、端末、署名方法、entitlements、対応ツールに左右されます。地域設定だけで有効になるものではありません。
- BIOS、ファームウェア、OS イメージ、ゲームなどを読み込む場合は、利用する権利があるファイルだけを使用してください。許可のないゲームや OS イメージを配布・共有しないでください。
- この文書は日本の法律、著作権、Apple アカウントに関する法的助言ではありません。権利やコンプライアンスに関する判断は、該当する公式情報や専門家に確認してください。

## 不具合の報告

可能な範囲で、次の情報を添えてください。

- iPhone／iPad の機種と iOS／iPadOS のバージョン
- Akatsubaki Emu のバージョン、commit、またはリリース URL
- インストール／署名ツールとそのバージョン
- 再現手順、期待した結果、実際の結果
- エラーメッセージ、関連するビルドログ、クラッシュログ

ログを共有する前に、Apple ID、確認コード、アクセストークン、非公開 URL、証明書、秘密鍵、その他の個人情報を必ず削除してください。

## 関連リンク

- [インストール手順（英語）](INSTALL.md)
- [公式ドキュメント／アーキテクチャ](https://akatsubaki-emu.github.io/docs/)
- [Kenran Butō ハイブリッド実行アーキテクチャ](docs/HYBRID_RUNTIME_ARCHITECTURE.md)
- [最初の実機 iOS プレイ可能ビルドの受け入れ基準](docs/FIRST_PLAYABLE_IOS_ACCEPTANCE.md)
- [サードパーティライセンス表示](THIRD_PARTY_NOTICES.md)
- [問題報告とコントリビューションガイド](CONTRIBUTING.md)

## ライセンス

プロジェクトが作成した Akatsubaki Emu のファイルは GPL-3.0-or-later でライセンスされています。サードパーティコンポーネントには、それぞれのライセンス条件が適用されます。詳細は [LICENSE](LICENSE)、[REUSE/DEP5](.reuse/dep5)、[サードパーティ告知](THIRD_PARTY_NOTICES.md)を参照してください。
