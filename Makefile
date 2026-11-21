.DEFAULT_GOAL := help
.NOTPARALLEL:

.PHONY: help macos macos-signed android verify

help:
	@printf '%s\n' \
	  'make macos         Mac向けReleaseアプリとZIPを生成（ad-hoc署名）' \
	  'make macos-signed  実行時に指定した証明書でMac版を署名' \
	  'make android       Android向けRelease APKを生成' \
	  'make verify        静的解析・テスト・protocol検査を実行' \
	  '署名には環境変数MACOS_SIGN_IDENTITYを指定してください。'

macos:
	@scripts/build.sh macos

macos-signed:
	@scripts/build.sh macos-signed

android:
	@scripts/build.sh android

verify:
	@scripts/verify.sh
