# code-docker-firecrawl

[code-docker](https://github.com/qwreey/code-docker) 에 자체 호스팅
[Firecrawl](https://github.com/firecrawl/firecrawl)(scrape/crawl → markdown API)을
붙이는 플러그인입니다. Firecrawl 자체를 고치거나 감싸지 않습니다 — 업스트림 이미지를
그대로 쓰고(딱 하나, DNS 포워더만 예외 — 아래 참고), **code-docker 안의 에이전트가 도구로
쓸 수 있게 붙이는 데 필요한 것만** 들어있습니다:

- 스택에 얹는 compose 오버레이 (`code-docker-firecrawl.yml`)
- `ootb.sh`/`migrate.sh`가 읽는 연동 메타데이터 (`ootb-manifest.env`)
- 인증 게이트 nginx 하나 (`docker/firecrawl-proxy/`)와 DNS 포워더 하나
  (`docker/dns-forwarder/`)

레포 이름이 `firecrawl-docker`가 아니라 `code-docker-firecrawl`인 이유가 이겁니다. 여기
있는 건 code-docker 밖에서는 쓸 데가 없습니다 (Firecrawl 혼자 띄우는 건 업스트림
`docker-compose.yaml` 하나면 끝나고, 이 레포가 도와줄 게 없습니다).

## 왜 dind 안이 아니라 code-docker 옆인가

Firecrawl의 fetcher(`firecrawl-api`, `playwright-service`)는 **공격자가 지정한 URL을
그대로 가져오는** 게 일입니다 — 그 URL이 걸어놓은 리다이렉트까지 스스로 따라갑니다.
`code-docker-internal`에는 인증 없는 webmanager(포트 81)와 router-manager/VNC 경로가
같이 있어서, 그 네트워크에 닿는 fetcher 하나가 곧 SSRF 한 방으로 관리 화면 전체에 닿는
경로가 됩니다.

dind 안에 넣는 것도 고려했지만 버렸습니다 — dind 안 컨테이너는 전부 하나의 도커
데몬/브리지를 공유해서 "이 둘은 나가고 저 셋은 못 나가게" 를 값싸게 나눌 방법이
없습니다. 그래서 이 레포는 code-docker 옆에 자기만의 `internal: true` 네트워크
(`firecrawl`)를 하나 만들고, 그 위에서만 Firecrawl을 돌립니다 — roblox-studio-docker의
VNC 격리망과 같은 모양입니다.

- `firecrawl-api`/`playwright-service`만 `netinit.provider` 라벨을 달아서 router를
  거쳐 나가는 경로를 받습니다.
- `redis`/`rabbitmq`/`nuq-postgres`는 라벨이 없어서 **경로가 전혀 없습니다** — 이름조차
  같은 네트워크 안(Docker 내장 DNS)만 풀립니다.
- `firecrawl-front`(nginx)만 `code-docker-internal`과 `firecrawl` 둘 다에 붙어서,
  `Authorization: Bearer $FIRECRAWL_TOKEN`을 확인한 요청만 `firecrawl-api:3002`로
  넘겨줍니다. Firecrawl 자체 호스팅 빌드에는 자체 키 검사가 없어서, 이 토큰이 유일한
  방어선입니다.

## 설치

code-docker 쪽에서:

```sh
./ootb.sh          # 새로 설치할 때
./migrate.sh       # 이미 돌고 있는 배포에 추가할 때
```

사이드 프로젝트를 붙이겠냐고 물으면 이 레포 URL을 넣으세요. 그러면:

1. `builds/code-docker-firecrawl/` 에 클론
2. `extra-include.yml` 에 오버레이 등록 + `.env` 의 `EXTRA_INCLUDE` 설정
3. **`FIRECRAWL_TOKEN`을 무작위로 생성**해서 `.env`에 씁니다 (사람이 정할 값이 아니라서
   묻지 않습니다)
4. **OpenAI API 키를 한 번 물어봅니다** (`FIRECRAWL_OPENAI_API_KEY`) — LLM 기반
   `/extract` 엔드포인트에만 쓰입니다. 엔터로 건너뛰어도 scrape/crawl/map은 전부 정상
   동작합니다.

그 다음 `docker compose up -d`.

## code-docker 안에서 쓰기

연동되면 `code-docker` 컨테이너 안에 `$FIRECRAWL_API_URL`(`http://firecrawl:3002`)과
`$FIRECRAWL_TOKEN`이 그대로 들어와 있습니다:

```sh
curl -s -H "Authorization: Bearer $FIRECRAWL_TOKEN" \
     -H "content-type: application/json" \
     "$FIRECRAWL_API_URL/v1/scrape" \
     -d '{"url":"https://example.com"}'
```

JS가 필요한 페이지(SPA 등)도 같은 엔드포인트로 되는지 확인하려면 `formats`에
`markdown`을 준 채로 무거운 페이지를 하나 던져보고, `playwright-service` 로그에 실제
렌더링이 찍히는지 보면 됩니다 — `firecrawl-api`가 필요할 때 자동으로
`playwright-service`를 거칩니다.

토큰 없이 호출하면 401이 돌아옵니다 (Firecrawl 자체 키 검사가 없으므로, 이게 유일한
게이트입니다):

```sh
curl -s -o /dev/null -w '%{http_code}\n' "$FIRECRAWL_API_URL/v1/scrape" \
     -H "content-type: application/json" -d '{"url":"https://example.com"}'
# 401
```

Claude Code(에이전트)에게는 그냥 `.env`/컨테이너 환경변수로 이미 들어와 있는
`FIRECRAWL_API_URL`/`FIRECRAWL_TOKEN`을 쓰라고 알려주면 됩니다 — 별도 MCP 서버 없이 REST
API 호출로 충분합니다.

## 인증: 토큰 하나가 전부입니다

**절대 비워두지 마세요.** `FIRECRAWL_TOKEN`이 비어있으면 firecrawl-front는 모든 요청을
401로 막습니다 ("인증 꺼짐" 모드가 없습니다) — 그러니 빈 토큰은 "덜 안전"이 아니라
"아예 안 됨"입니다.

`FIRECRAWL_TOKEN`이 있어도 지켜지는 범위는 **firecrawl-front를 거치는 경로 하나뿐**입니다.
Firecrawl 자신의 `/v1/*` API에는 자체 키 검사가 없으므로(`USE_DB_AUTHENTICATION=false`),
`firecrawl` 네트워크 안에서 직접 `firecrawl-api:3002`에 닿을 수 있는 주체(즉 이 오버레이
안의 다른 컨테이너들)는 토큰 없이도 API를 씁니다 — 이건 의도된 것입니다. 이 네트워크
안에는 애초에 Firecrawl 자신의 컨테이너들만 있고, 그 경계(`internal: true` + 라벨
기반 egress)가 실제 방어선입니다.

## 제한 / 알아둘 것

- **DB 인증/`/extract`용 LLM 키를 뺀 나머지는 전부 익명 self-host 기본값입니다.**
  Supabase 연동, Autumn(과금), SearchApi 같은 건 안 붙였습니다 — 필요하면
  `code-docker-firecrawl.yml`의 `firecrawl-api` environment에 직접 추가하세요.
- **큐 데이터(`nuq-postgres`)는 이름 있는 볼륨에 남습니다** (`code-docker-firecrawl-postgres-data`,
  `docker volume ls`로 찾을 수 있습니다) — `redis`/`rabbitmq`는 휘발성입니다(진행 중인
  작업이 재시작으로 날아갈 수 있습니다).
- **이미지 태그는 firecrawl-api만 실제 버전으로 고정됩니다** (`FIRECRAWL_TAG`, 기본
  `2.11.408`). 업스트림이 GitHub Release를 따로 안 끊고 커밋마다 새 semver 태그를
  올리는 구조라, trilium 처럼 "릴리스 노트 보고 올리기"가 아니라 그냥 주기적으로
  ghcr.io 태그 목록을 확인하고 올려야 합니다. `playwright-service`/`nuq-postgres`는
  업스트림에 `latest` 말고 다른 태그가 없어서 그대로 씁니다.
- **호스트에 게시되는 포트가 없습니다.** 바깥에서 닿는 경로는 아예 없고, code-docker
  안의 에이전트만 `firecrawl-front`를 거쳐 씁니다.
- **`firecrawl` 네트워크는 서브넷이 고정돼 있습니다** (`FIRECRAWL_SUBNET`, 기본
  `10.89.42.0/24`) — Compose의 서비스별 `dns:` 필드가 IP 리터럴만 받기 때문에
  DNS 포워더(`firecrawl-dns`) 주소를 미리 알아야 해서입니다. 호스트에서 이 대역이
  겹치면 `FIRECRAWL_SUBNET`/`FIRECRAWL_DNS_IP`를 같이 바꾸세요.

## 이 레포가 code-docker에 요구하는 것

이미 code-docker 쪽에 있는 **범용 기능**만 씁니다 — 이 플러그인 전용 코드가 저쪽에
들어가 있지는 않습니다:

| 기능 | 어디 | 문서 |
|---|---|---|
| `netinit.provider`/`netinit.gateway`/`netinit.exempt-forward` 라벨 | code-docker-netinit-docker | `CLAUDE.md`의 "docker-compose topology" |
| `EXTRA_INCLUDE` + `ootb-manifest.env` | `ootb.sh`/`migrate.sh` | `docs/tips/ootb-manifest.md` |
| 서비스에 필드만 병합하는 include 병합 (`code-docker`/`code-docker-router`) | Compose 자체 | `code-docker-trilium`/`roblox-studio-docker`에서 먼저 검증됨 |
