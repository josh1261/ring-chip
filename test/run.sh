#!/bin/bash
# 이 폴더 경로("앱 개발")에 띄어쓰기가 있어 make가 깨지므로,
# 띄어쓰기 없는 바로가기(~/.tt/ring-chip)와 가상환경(~/.venvs/ring-chip)으로 실행한다.
# 사용법: test/run.sh            (전체 테스트)
#        test/run.sh TESTCASE=이름 (테스트 하나만)
set -e
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$HOME/.venvs/ring-chip" ] || { python3 -m venv "$HOME/.venvs/ring-chip"; "$HOME/.venvs/ring-chip/bin/pip" install -q -r "$PROJ/test/requirements.txt"; }
mkdir -p "$HOME/.tt"; ln -sfn "$PROJ" "$HOME/.tt/ring-chip"
cd "$HOME/.tt/ring-chip/test"
export PWD="$HOME/.tt/ring-chip/test"
PATH="$HOME/.venvs/ring-chip/bin:$PATH" make "$@"
