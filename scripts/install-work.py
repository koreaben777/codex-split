#!/usr/bin/env python3
"""First installation using the existing verified build, setup and deployment paths."""
from pathlib import Path
import os
import pwd
import shutil
import subprocess
import sys

BASE = Path(__file__).resolve().parent.parent
HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)  # account database, not $HOME
WORK_ROOT = HOME / 'Library/Application Support/CodexSplit/profiles/work'
DESTINATION = HOME / 'Applications/CodexSplit-work.app'
OFFICIAL_APP = Path('/Applications/ChatGPT.app')


def main(args):
    if args == ['--help']:
        print('Usage: sh scripts/install.sh\n처음 설치 전용: 검사·빌드 → 직접 업무 로그인 → 런처 설치.\n'
              'Terminal에서 실행하세요. 준비 사항·중단 후 재개: docs/INSTALL.md')
        return
    if args:
        raise RuntimeError('지원하지 않는 인자. sh scripts/install.sh --help를 확인하세요.')
    if sys.platform != 'darwin':
        raise RuntimeError('macOS에서만 설치할 수 있습니다.')
    if os.geteuid() == 0:
        raise RuntimeError('sudo 없이 사용할 본인 macOS 계정으로 실행하세요.')
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise RuntimeError('Terminal 창에서 직접 실행하세요. 로그인 확인에 대화형 입력이 필요합니다.')
    for path in (DESTINATION, WORK_ROOT):
        if os.path.lexists(path):
            raise RuntimeError('기존 설치 또는 업무 프로필이 있습니다: ' + str(path)
                               + '\n처음 설치를 다시 진행하지 않습니다. docs/INSTALL.md의 기존 설치·중단 후 재개를 확인하세요.')
    if not OFFICIAL_APP.is_dir():
        raise RuntimeError('공식 ChatGPT 앱을 /Applications/ChatGPT.app에 먼저 설치하세요.')
    for tool in ('xcrun', 'codesign', 'git'):
        if not shutil.which(tool):
            raise RuntimeError(tool + '가 필요합니다. xcode-select --install 완료 후 다시 실행하세요.')
    for tool in ('swiftc', 'clang'):
        subprocess.run(['xcrun', '--find', tool], check=True)

    print('처음 설치를 시작합니다. 빌드·전체 검사에는 시간이 걸립니다.\n'
          '설치된 공식 앱에 맞춰 Sources/AppTrial.swift의 고정값이 변경될 수 있습니다.\n'
          '검사 후 업무 창에서 직접 로그인하고 Terminal 안내에 따라 계정·종료를 확인하세요.\n'
          '이 소스 폴더는 이후 업데이트에 필요하므로 이동하거나 삭제하지 마세요.', flush=True)
    commands = [
        ('1/6 검사 도구 빌드', ['sh', 'scripts/build.sh']),
        ('2/6 공식 앱 서명·버전 확인 및 고정', [sys.executable, 'scripts/update-work.py', '--pin-installed']),
        ('3/6 전체 검사·런처 빌드', ['sh', 'scripts/check.sh']),
        ('4/6 업무 계정 설정', [str(BASE / '.build/codex-split-work-setup'), '--setup', 'work']),
        ('5/6 공식 앱 버전 재확인', [str(BASE / '.build/codex-split'), 'update-check', 'work', '--json']),
        ('6/6 런처 설치', [sys.executable, 'scripts/install-work-update-approved.py', '--install-new']),
    ]
    for label, command in commands:
        print('\n' + label, flush=True)
        subprocess.run(command, cwd=BASE, env={**os.environ, 'CODEXSPLIT_SOURCE_ROOT': str(BASE)}, check=True)
    print('\n설치 완료: ' + str(DESTINATION)
          + '\nFinder에서 이 앱을 열어 수용 시험 두 번과 일상 사용 허용을 마치세요.\n'
          '자세한 안내: ' + str(BASE / 'docs/INSTALL.md'), flush=True)


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (RuntimeError, OSError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print('\n설치 중단: ' + str(error) + '\n이미 생성된 프로필·기록은 삭제하지 않습니다. '
              'docs/INSTALL.md의 중단 후 재개를 확인하세요.', file=sys.stderr)
        sys.exit(2)
