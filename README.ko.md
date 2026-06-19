# youtube-parallel-crawl-nordvpn

> 🌐 **English**: [README.md](README.md) · **한국어**: 이 문서

**워커마다 서로 다른 exit IP**로 YouTube 영상(오디오 + 메타데이터)을 **대규모 병렬**로 크롤링합니다. 각 워커는 자기만의 네트워크 네임스페이스(network namespace) 안에서 동작하므로, **호스트의 기본 경로(default route)는 절대 건드리지 않습니다.** 즉 SSH, 에이전트, `api.anthropic.com` 같은 호스트의 연결은 VPN을 타지 않고 원래 회선을 그대로 유지합니다. 그러는 동안 워커들은 그 아래에서 IP를 갈아끼웁니다.

이 저장소는 깨끗한 리눅스 머신에 클론하기만 하면 동작하도록 설계된 **자기완결형(self-contained) 배포 가능 프로젝트**입니다. 필요한 것은 NordVPN 계정 하나뿐입니다.

---

## 동작 원리 (한눈에)

- 워커 = 하나의 `vopono exec` 네임스페이스. 하나의 서버(= 하나의 exit IP)에 바인딩됩니다.
- 워커 `i`는 **`COUNTRIES[i]`** 국가에 고정되고, **그 국가의 서버들 안에서만** IP를 회전합니다. 따라서 살아 있는 W개의 IP는 항상 W개의 서로 다른 대역(distinct range)에 위치합니다.
- 작업 분할: 평평한 ID 목록을 **`index % WORKERS`** 로 나눠 서로 겹치지 않는(disjoint) 샤드로 만듭니다. 워커 간 조율(coordination)이 전혀 필요 없습니다.
- 크롤러는 **VPN을 전혀 다루지 않습니다.** `nordvpn`이나 `vopono`를 직접 호출하지 않습니다. IP는 바깥쪽 네임스페이스가 소유합니다.
- 슈퍼바이저(`crawl.sh`)는 **root**로 실행됩니다(네임스페이스에 필요). 다만 vopono에는 `--user <you>`를 넘겨 다운로드 파일이 root가 아닌 일반 사용자 소유로 남게 하고, `HOME`을 전달해 vopono가 동기화한 설정을 찾도록 합니다.
- 재개(resume): 디스크 상의 `audio/<id[:2]>/<id>.<ext>` 와 샤드별 `archive.shard<N>.txt`. 이미 처리된 ID는 매 배치 시작 시 작업 집합에서 제거(prune)됩니다.

---

## ⭐ TL;DR — 실제로 동작하는 설정

두 가지 결정이 핵심입니다. 처음부터 이대로 가세요.

1. **OpenVPN이 아니라 WireGuard.** OpenVPN은 연결할 때마다 재인증합니다. NordVPN은 인증 횟수를 rate-limit 하므로, W개의 워커가 병렬로 자주 재연결하면 재시도 폭주(retry cascade)가 일어나 함대 전체가 무너집니다(레퍼런스 실행에서 약 8분 만에 붕괴). WireGuard는 **정적 키(static key)** 를 쓰므로 연결마다 인증이 없고, 따라서 throttle 당할 것 자체가 없습니다.
2. **워커당 서로 다른 국가 하나씩 (한 국가에 여러 서버 X).** 한 제공자의 같은 국가 서버들은 몇 개 안 되는 /24에 몰려 있습니다. W개의 워커가 같은 /24에 올라가면 YouTube의 **서브넷 단위(subnet-level)** 봇 탐지에 걸립니다(약 86%가 "not a bot"). 워커를 국가별로 흩뿌려 W개의 IP가 W개의 서로 다른 /16에 놓이게 하세요.

```bash
git clone <this-repo> && cd youtube-parallel-crawl-nordvpn
cp config.example.env config.env        # 편집: COUNTRIES, WORKERS, IDS_FILE 등
cp examples/ids.example.txt ids.txt     # 본인의 ID/URL 목록으로 교체

sudo bin/install.sh                      # vopono + wireguard-tools (.deb, cargo 불필요)
vopono sync nordvpn                       # 본인이 실행: NordVPN 서비스 자격증명 동기화
sudo bin/setup.sh                         # 서버 풀 + WireGuard 설정 생성 + AppArmor 수정
nordvpn disconnect && nordvpn set killswitch off   # 호스트를 VPN에서 분리
bin/verify.sh                             # 격리 검증(호스트 깨끗함 / IP 중복 없음)
./crawl.sh                                # 크롤 시작 (sudo 한 번 요청)
bin/status.sh                             # 실행 여부 / 활성 워커 / 속도 / 누계
```

레퍼런스 실행의 정상 상태: **분당 약 86–96건, 인증 실패 0, 봇 탐지 0, 붕괴 없음.** (OpenVPN + 단일 국가 구성은 약 8분 만에 봇 탐지 약 86%로 붕괴했습니다.)

---

## 설정 (`config.env`)

`config.example.env`를 `config.env`로 복사해 편집하세요. 모든 값은 동일한 이름의 환경 변수로 커맨드라인에서 덮어쓸 수 있습니다. 예: `WORKERS=4 ./crawl.sh`

| 변수 | 기본값 | 의미 |
|---|---|---|
| `IDS_FILE` | `./ids.txt` | 한 줄에 YouTube 영상 ID **또는** 전체 URL 하나 |
| `OUTPUT_DIR` | `./output` | `audio/`, `logs/`, `archive.shard<N>.txt`의 루트 |
| `YTDLP_FORMAT` | `140/bestaudio[ext=m4a]/bestaudio` | yt-dlp `-f` 포맷 선택자 |
| `COOKIES_FILE` | `""` | 선택: `cookies.txt` (연령/봇 게이트 다수 우회) |
| `VPN_PROVIDER` | `nordvpn` | VPN 제공자 |
| `VPN_PROTOCOL` | `wireguard` | `wireguard`(권장: 인증 throttle 없음) \| `openvpn` |
| `COUNTRIES` | `south_korea japan ...` | **워커당 서로 다른 국가 하나.** 공백 구분, `WORKERS` 개 이상 |
| `WORKERS` | `8` | 병렬 워커 수. `COUNTRIES` 개수 이하, 그리고 9 이하(NordVPN 10연결 상한) |
| `THREADS` | `2` | IP당 워커 내부 동시성 (2 = YouTube 안전선; >2면 IP 단위 탐지에 걸림) |
| `LIMIT` | `60` | 다음 서버로 회전하기 전 IP당 성공 다운로드 수 |
| `BLOCK_BUDGET` | `20` | 배치를 일찍 끝내기 전 IP당 허용 차단 수 (403은 대부분 일시적) |
| `SETUP_WINDOW` | `8` | 워커당 setup-lock 보유 시간(초) (WireGuard 약 5–8, OpenVPN 약 20) |
| `STAGGER` | `8` | 워커 최초 기동 간 간격(초) |
| `SETTLE` | `3` | 네임스페이스 정리 후 다음 기동까지 기본 대기(초, jitter 적용) |
| `MAX_FAILS` | `8` | 워커를 중단시키는 연속 setup 실패 횟수 |
| `MIN_SUBSET` | `3` | IP 재사용 전 워커가 돌아야 할 최소 서로 다른 서버 수 |
| `CAP` | `9` | 지킬 NordVPN 동시 연결 상한 |
| `AUTH_COOLDOWN` | `150` | OpenVPN 전용: 인증 throttle 감지 시 전체 일시정지(초) |
| `POOL_FILE` | `./servers.txt` | 생성된 서버 풀 |
| `WG_DIR` | `/etc/wireguard/nordwg` | 생성된 서버별 WireGuard 설정(root 소유) |
| `VENV` | `./.venv` | yt-dlp가 설치된 파이썬 venv |

---

## 저장소 구조

```
youtube-parallel-crawl-nordvpn/
  config.example.env          # 표준 설정(계약). config.env로 복사
  crawl.sh                    # 슈퍼바이저 엔트리포인트
  bin/
    install.sh                # vopono + 의존성 설치(root)
    setup.sh                  # 서버 풀 + WireGuard 설정 생성 + AppArmor 수정(root)
    verify.sh                 # 격리 검증(호스트 깨끗함 / IP 구분 / 터널 정상)
    status.sh                 # 실행 여부 / 활성 워커 / 속도 / 누계
    watch.sh                  # 붕괴 감시(정상이면 조용, 이상 시 경보)
    cleanup.sh                # 크래시/강제종료 후 vopono 잔재 정리(root)
  crawler/
    crawler.py                # 샤드별 워커(네임스페이스 안에서 실행)
    requirements.txt          # yt-dlp 등
  examples/ids.example.txt    # 예시 입력
  .claude/skills/youtube-parallel-crawl-nordvpn/SKILL.md   # Claude skill (자동 인식)
  README.md / README.ko.md
```

### 출력 레이아웃 (`OUTPUT_DIR` 아래)

```
$OUTPUT_DIR/
  audio/<id[:2]>/<id>.<ext>      # yt-dlp 오디오
  audio/<id[:2]>/<id>.meta       # 정제된 yt-dlp 메타데이터(json)
  logs/<id[:2]>/<id>.log         # 영구 실패(unavailable/private/...)에 대해서만 마커 기록
  logs/parallel/worker<i>.out    # 워커별 로그
  archive.shard<N>.txt           # 샤드별 다운로드 아카이브 → 재개 가능
```

---

## 사전 준비 (한 번만)

리포지토리를 클론한 직후 순서대로:

1. **`cp config.example.env config.env`** 후 편집. 최소한 `COUNTRIES`(≥ `WORKERS` 개)와 `IDS_FILE`을 본인 환경에 맞추세요.
2. **`cp examples/ids.example.txt ids.txt`** 후 본인의 ID/URL 목록으로 교체. 빈 줄과 `#`으로 시작하는 줄은 무시됩니다.
3. **`sudo bin/install.sh`** — `vopono`(GitHub release의 amd64 `.deb`, Rust 툴체인 불필요) + `wireguard-tools`, `openvpn`, `iproute2`, `curl`을 설치합니다.
4. **`vopono sync nordvpn`** — **본인 사용자로** 실행. NordVPN **서비스** 자격증명을 입력합니다(슈퍼바이저는 한 번만 sudo로 자기 승격하므로 NOPASSWD sudoers는 필요 없음).
5. **`sudo bin/setup.sh`** — `POOL_FILE`(서버 풀)을 생성하고, WireGuard 모드라면 서버별 설정을 `WG_DIR`에 만들고 AppArmor 허용 규칙을 추가합니다(아래 "벽 4" 참조).
6. **`nordvpn disconnect && nordvpn set killswitch off`** — 호스트를 VPN에서 분리. 네임스페이스만 VPN을 타게 합니다(SSH는 LAN 위에 있어 그대로 유지).
7. **`bin/verify.sh`** — 수락 기준 점검(sudo 요청).

---

## 실행

```bash
./crawl.sh                            # config.env 설정대로 전체 ID 크롤(이미 받은 건 재개)
WORKERS=4 LIMIT=40 ./crawl.sh         # 환경 변수로 노브 조정(sudo로 전달됨)
nohup ./crawl.sh > crawl.out 2>&1 &   # 백그라운드 + 로깅
```

슈퍼바이저는 네임스페이스에 필요한 root 권한을 위해 **`sudo`로 한 번 자기 승격**합니다. `HOME`을 전달해 vopono가 동기화한 설정을 찾고, `--user`로 다운로드 파일을 본인 소유로 유지합니다. `Ctrl-C`로 멈추면 네임스페이스를 정리하고 NordVPN 연결 슬롯을 반납합니다. 완전히 재개 가능합니다.

### 크롤러 CLI (샤드별 워커)

크롤러는 **vopono 네임스페이스 안에서** 실행되며, vopono를 절대 직접 호출하지 않습니다. 슈퍼바이저가 호출하는 형태:

```bash
$VENV/bin/python crawler/crawler.py IDS_FILE OUTPUT_DIR \
  --num-shards N --shard i --threads C --limit L --block-budget B \
  [--format FMT] [--cookies FILE]
```

한 줄당 영상 ID 또는 전체 URL을 읽고, `index % N == i`인 항목만 처리합니다. yt-dlp로 오디오 + 메타를 받고, 재개 가능합니다.

### 배치 종료 코드 (워커 ↔ 슈퍼바이저)

- **`64`** — 샤드 완료(정리된 작업 집합이 비었음: 모든 ID가 다운로드되었거나 영구 마커가 찍힘) → 해당 워커 재기동 중단.
- **`0`** — 배치가 진척을 냄 → 다음 IP로 회전 후 재기동.
- **`75`** — 배치가 아무것도 못 받음(나쁜 IP / 차단 / 막힘) → IP 회전. 서브셋 전체를 두 바퀴 돌고도 진척이 없으면 워커가 그 샤드 루프를 큰 소리로 중단합니다(나중에 다른 IP로 재시도).

중단되거나 막힌 워커는 보고되며, 슈퍼바이저는 "INCOMPLETE SHARD(S)"와 함께 0이 아닌 코드로 종료합니다 — 거짓으로 "모든 샤드 완료"를 출력하지 않습니다.

---

## yt-dlp 실패 분류 (회전/재시도를 올바르게)

크롤러는 yt-dlp 에러를 세 부류로 나눠 처리합니다.

- **BLOCK** (새 IP에서 재시도, 마커 **기록 안 함**, 다시 큐에 넣음): `429`, `Too Many Requests`, `not a bot`, `Please sign in`, `403`.
  - ⚠️ yt-dlp는 `you're`에 **둥근 따옴표(curly apostrophe)** 를 씁니다. 절대 `you're`로 매칭하지 말고 부분 문자열 **`not a bot`** 로 매칭하세요.
- **PERMANENT** (스킵 마커 기록, 재시도 안 함): `Video unavailable`, `Private video`, `removed by the uploader`, `who has blocked it`(저작권), `no longer available`, 계정 `terminated`, `Sign in to confirm your age`(연령 게이트 ≠ 봇).
- **TRANSIENT** (마커 없이 재시도): HTTP 5xx, 타임아웃, `Network unreachable`.

샤드가 "완료"인 것은 단지 한 배치가 비었을 때가 아니라, **정리된 작업 집합이 비었을 때**(모든 ID가 다운로드되었거나 영구 마커가 찍힘)뿐입니다.

---

## 검증 / 수락 기준 (`bin/verify.sh`)

1. **호스트가 깨끗함** — 호스트의 `curl ifconfig.me`가 VPN IP가 아니라 머신의 실제 ISP IP여야 함.
2. **IP가 서로 다름** — 모든 워커 네임스페이스가 서로 다른 exit IP를 보고하며, 어느 것도 호스트와 같지 않음.
3. **터널이 실제로 살아 있음** — 각 IP가 네임스페이스 내부에서 도달 가능함.
4. **세션 유지** — 호스트가 VPN 밖에 있으므로 실행 내내 SSH/에이전트가 끊기지 않음.
5. **중복 크롤 없음** — 샤드는 `index % WORKERS`로 구조적으로 겹치지 않으며, 전체에 대해 완전성이 보장됨.

---

## 모니터링 & 복구

- **`bin/status.sh`** — 실행 여부 / 활성 워커 / 속도 / 누계. (`vopono exec` 프로세스를 세며, `openvpn`을 세지 않습니다. WireGuard는 커널 `wg` 인터페이스를 쓰므로 `openvpn=0`이 정상입니다.)
- **`bin/watch.sh`** — 정상이면 조용히 `OK`. 새 abort 급증, 인증 실패 재발, 속도 정체(실행 중인데 분당 약 10건 미만), 또는 슈퍼바이저 사망 시 `COLLAPSE/CRASHED/FINISHED`를 출력합니다. 짧은 cron에 걸어 두고 non-OK일 때만 알림을 받으세요.
- **`bin/cleanup.sh`** — 크래시/강제종료 후 **재시작 전에 반드시 실행**하세요. 고아가 된 `vo_nd_*` veth/네임스페이스와 vopono의 NetworkManager `unmanaged.conf`(이게 없으면 동시 기동이 panic)를 정리합니다. 호스트에 안전합니다 — `vo_nd_*` 인터페이스만 건드리고 NetworkManager는 재시작이 아니라 reload하므로 WiFi/SSH는 유지됩니다.

---

## 처리량 튜닝

`WORKERS`를 1→9로 늘리며 워커 로그 전반의 합계 분당 다운로드를 관찰하세요. 업링크/대상 rate-limit/CPU가 포화되기 전까지 거의 선형으로 증가합니다 — 무릎(knee) 지점 직전에서 멈추세요. `LIMIT`(회전 전 IP당 다운로드)을 키우면 회전 오버헤드를 분산할 수 있지만, IP당 차단 한계 안에서 머무르세요. 하드 천장은 NordVPN의 10슬롯 상한입니다. 그 이상이 필요하면 **로테이팅 residential/datacenter 프록시 풀**로 전환해야 합니다(vopono는 "깨끗하고 격리된 소수의 IP"를 위한 도구입니다).

---

## 어렵게 얻은 사실들 (반드시 지킬 것)

이 프로젝트가 다일(multi-day) 실제 운영에서 단련되며 가장 많은 시간을 잡아먹은 비자명한 일곱 개의 벽입니다. 동작하는 설정에서 출발하고, 다시 유도하지 마세요.

### 벽 1 — 약 86%가 "Sign in to confirm you're not a bot"
- **원인:** W개의 워커가 한 제공자의 /24에 몰리면 YouTube의 서브넷 단위 남용 탐지가 그 /24 전체를 플래그합니다. (같은 IP들을 **한 번에 하나씩** 쓰면 약 1.5%였습니다.) 제공자의 같은 국가 서버는 의외로 적은 수의 /24에 모여 있습니다(NordVPN KR = 약 5개 /24).
- **해결:** **워커당 서로 다른 /16(국가)** 하나씩. 핵심 교훈 — 데이터센터 IP 차단은 회전 *빈도*가 아니라 주소 **다양성**의 문제입니다. 플래그된 하나의 /24 안에서 빨리 회전해 봤자 소용없습니다.

### 벽 2 — 빠르게 돌다가 함대 전체가 0으로 붕괴 (OpenVPN)
- **증상:** `OpenVPN authentication failed`가 워커들로 번지고(대부분 재시도), 캐스케이드 후 전부 abort.
- **원인:** OpenVPN의 연결마다 인증 + NordVPN의 인증 rate-limit + 병렬 재연결 churn.
- **해결:** **WireGuard**(벽 4 참조). 정적 키라 연결마다 인증이 없으니 throttle 당할 게 없습니다. 일부 병목은 파라미터가 아니라 **아키텍처**입니다.

### 벽 3 — 동시에 시작하면 8개 워커가 abort
- **증상:** `Failed to restore backup of NetworkManager unmanaged.conf: NotFound`, `RTNETLINK: File exists`, `Failed to create veth pair`.
- **원인:** 동시 `vopono exec`가 공유 파일 `/etc/NetworkManager/conf.d/unmanaged.conf`에서 경쟁(veth 생성 panic). 강제종료된 실행은 `vo_nd_*` veth/네임스페이스 잔재를 남깁니다.
- **해결:** 짧은 setup 구간만 전역 `flock`으로 **직렬화**(vopono가 netns/veth/NM을 구성하는 동안만 락을 잡고, 긴 다운로드가 병렬로 돌기 전에 해제). 최초 기동은 stagger, 재기동은 jitter. SIGKILL이 아닌 SIGTERM으로 깔끔히 정리해야 VPN 세션이 반납됩니다. `bin/cleanup.sh`가 잔재를 청소합니다. "동시성 지원" ≠ "동시 *기동*이 안전".

### 벽 4 — WireGuard: `Wireguard not implemented` / `fopen: Permission denied` / NO_HANDSHAKE
- **원인 A:** vopono가 NordVPN WireGuard를 `sync`할 수 없음 → 손수 만든 설정을 `vopono exec --custom <wg.conf>`로 사용.
- **원인 B (진짜 차단 요인):** **AppArmor** `wg` 프로파일이 vopono가 설정을 복사해 두는 `/tmp` 읽기를 막음. 증상은 `fopen: Permission denied` + 조용한 NO_HANDSHAKE. `dmesg | grep -i 'apparmor.*DENIED.*wg'`로 확인.
- **해결:** `echo '/tmp/vopono*.conf r,' >> /etc/apparmor.d/local/wg && apparmor_parser -r /etc/apparmor.d/wg` (`bin/setup.sh`가 자동으로 수행).
- **토큰 불필요:** 계정에 등록된 WireGuard 개인 키는 이미 호스트에 있습니다 — `sudo wg show nordlynx private-key`. 각 서버의 WG **공개 키 + 엔드포인트**는 **공개** API `https://api.nordvpn.com/v1/servers?limit=8000`에서 옵니다(서버별 `technologies[].identifier=="wireguard_udp"` → `metadata`의 `public_key`, Endpoint = `station:51820`). 설정: `Address=10.5.0.2/32`, `AllowedIPs=0.0.0.0/0`, `DNS=103.86.96.100`. `bin/setup.sh`가 이를 모두 처리해 `WG_DIR`에 서버별 설정을 만듭니다.

### 벽 5 — 다운로드가 느려지며 `Temporary failure in name resolution` 폭증
- **원인:** 제공자(NordVPN) **자체 DNS가 `WORKERS`개 병렬 네임스페이스의 질의량에 rate-limit**. 터널은 살아있는데 이름 해석만 막혀 처리량이 무너집니다.
- **해결:** vopono `--dns 1.1.1.1`(`VPN_DNS`). 질의는 **터널을 통해** 나가므로 exit IP는 그대로이고 누출도 없습니다. (벽 7과 구분: 거기선 *터널 자체*가 죽습니다.)

### 벽 6 — country-pinning은 너무 나이브 → 공유 IP 풀 (리스 + 휴면)
- **문제:** 워커를 한 국가에 **고정**하면 (a) 두 워커가 같은 IP를 동시에 쓸 수 있고, (b) 플래그된(차단된) IP를 잠시 격리할 방법이 없습니다.
- **해결:** 모든 워커가 **하나의 공유 풀에서 IP를 리스(lease)**. `flock`으로 4가지를 보장 — ① 동시 중복 IP 없음 ② 라이브 IP는 서로 다른 국가(distinct /16) ③ 막 반납한 IP는 즉시 재사용 금지(`RECENT_SEC`) ④ 봇-플래그된 IP는 `COOLDOWN_MIN`분 **휴면**(절대 조기 재배정 안 함). 크래시한 워커의 리스는 `LEASE_TTL` 후 회수. 플래그 신호 = 한 배치당 `not a bot | VPN/Proxy Detected | HTTP 429` 누적 ≥ `BOT_FLAG_THRESHOLD` **또는** 403 ≥ `BLOCK_BUDGET`.
- **핵심 함정:** **"VPN/Proxy Detected"가 "not a bot"보다 흔한 차단 신호** — 둘 다 잡아야 휴면이 제대로 작동합니다. 봇 탐지는 0이 아니라 **저-중 수준**으로 남습니다(상용 VPN IP는 본질적으로 일부 플래그됨); 휴면이 최악의 IP만 격리해 처리량을 회복시킬 뿐, 완전 제거는 **쿠키**(`COOKIES_FILE`, 인증 요청)뿐입니다.

### 벽 7 — 잘 돌다가 ~1시간 후 전 터널 사망 (`wg show` = `0 B received` / `handshake=NONE`)
- **증상:** 모든 서버에서 핸드셰이크 0바이트 수신인데, **호스트는** 엔드포인트에 ICMP/UDP 51820 정상 도달.
- **원인:** NordVPN이 **계정의 WireGuard 핸드셰이크를 rate-limit**. 공유 풀은 다양성을 위해 distinct 서버를 많이 churn → 핸드셰이크가 많음(옛 country-pinning은 서버를 재사용해 14시간 버팀). 결정타는 터널이 죽은 뒤 워커들이 살아있는 서버를 찾아 **미친 듯이 회전하는 폭주**(측정: 5분에 32 distinct 서버) — 바로 이 패턴이 리밋을 트리거하고 0에 **고착**시킵니다.
- **해결:** **연결실패 지수 백오프**(`CONN_RE`) — 배치가 (YouTube 차단이 아닌) *연결* 오류로 통째로 실패하면 최대 120초 백오프하고 STUCK 카운트에서 제외 → 폭주 대신 조용히 대기 → 리밋이 리셋되고 다운로드 **자가 회복**. 추가로 `LIMIT` 상향(기본 핸드셰이크 빈도 감소), 그래도 재발하면 풀/`COUNTRIES` 축소로 IP 재사용을 늘립니다. 급하면 함대를 1~2분 정지 후 재시작하면 리밋이 풀립니다.

### vopono 주의점 (버전 0.10.x)
- 애플리케이션은 **하나의 인자**입니다(vopono가 shell-split). `-- cmd args`가 아니라 `vopono exec ... "yt-dlp -x URL"` 형태. 따옴표 없는 `-x`/`-s`는 vopono 플래그로 파싱됩니다.
- OpenVPN에서 `--server`는 **전체 설정 이름**과 매칭됩니다(`south_korea-kr112`, `kr112` 아님).
- vopono를 root로 실행하면 배치마다 sudo 프롬프트가 없습니다. `--user <you>`로 파일 소유권을 유지하고, `HOME`을 전달해 `~/.config/vopono`를 찾게 합니다.
- 상한: NordVPN = 동시 10연결 → `WORKERS ≤ 9` 유지. 워커마다 서로 다른 서버를 쓰세요(공유하면 두 워커가 같은 IP를 갖게 됨).
- **호스트는 VPN 밖에 둡니다. 호스트 경로는 절대 건드리지 않습니다 — 그게 이 프로젝트의 핵심입니다.**

---

## 다른 제공자/대상으로 적용하기

- **다른 VPN:** 패턴은 그대로입니다 — 앱별 네임스페이스 격리 + 서로 다른 대역의 워커 + 연결마다 인증하는 프로토콜보다 정적 키(WireGuard) 선호.
- **약 10개 이상의 서로 다른 IP가 필요하면:** NordVPN 상한은 단단합니다. **로테이팅 residential/datacenter 프록시 풀**로 전환하세요(vopono는 "깨끗하고 격리된 소수의 IP"를 위한 도구).
- **YouTube가 아닌 대상:** 격리/다양성/실패 분류의 뼈대는 유지하고, 다운로더와 block/permanent/transient 문자열 매칭만 교체하세요.

---

## Claude Code skill로 설치

이 repo에는 [Agent Skill](https://agentskills.io)(Claude Code · Claude 앱 · Agent
SDK에서 공유되는 오픈 포맷)이 `.claude/skills/youtube-parallel-crawl-nordvpn/SKILL.md`
에 포함되어 있습니다. 운영 playbook과 네 개의 벽을 담고 있어, 에이전트가 검증된
설정에서 바로 시작합니다.

**설치 방법 두 가지:**

```bash
# A) 프로젝트 skill (자동 인식) — 클론한 repo 폴더 안에서 작업:
git clone https://github.com/sakemin/youtube-parallel-crawl-nordvpn
cd youtube-parallel-crawl-nordvpn
claude          # Claude Code가 이 프로젝트의 .claude/skills/를 자동 인식
                # (Claude Code 시작 시 .claude/skills/가 없었다면 재시작 필요)

# B) 개인 skill (전역) — 모든 프로젝트에서 사용:
mkdir -p ~/.claude/skills/youtube-parallel-crawl-nordvpn
cp .claude/skills/youtube-parallel-crawl-nordvpn/SKILL.md \
   ~/.claude/skills/youtube-parallel-crawl-nordvpn/
# 그 다음 Claude Code 재시작 / 새 세션
```

병렬 YouTube 크롤, 워커별 VPN IP, YouTube bot-detection / 429 / 403을 물어보면
자동으로 활성화됩니다. 오픈 Agent Skill이라 같은 `SKILL.md`가 claude.ai와 Agent
SDK에서도 동작합니다.

---

## 라이선스

[LICENSE](LICENSE)를 참고하세요.
