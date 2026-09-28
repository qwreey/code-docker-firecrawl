# code-docker-firecrawl

[code-docker](https://github.com/qwreey/code-docker) 에 자체 호스팅
[Firecrawl](https://github.com/firecrawl/firecrawl)(scrape/crawl → markdown API)을
붙이는 플러그인입니다.

**2026-09-28부터 AIO(all-in-one) 컨테이너 하나로 돕니다.** postgres, redis,
playwright-service, api harness가 전부 이 컨테이너 안에서 supervisord 프로그램으로
돕니다 (Nextcloud-AIO 스타일). 예전엔 업스트림 이미지를 그대로 쓰는 7-컨테이너 스택
(firecrawl-api, playwright-service, redis, rabbitmq, nuq-postgres, DNS 포워더, 인증
게이트)이었는데, 이제는 이 레포가 Firecrawl을 소스(고정된 git 태그)에서 직접 빌드하기
때문에 그 안에 supervisord를 넣을 수 있게 됐고, rabbitmq와 DNS 포워더 사이드카가
통째로 사라졌습니다. 자세한 이유는 `CLAUDE.md`의 "Why AIO, and what changed" 참고.

- 컨테이너 이미지 빌드/구성 (`Dockerfile`, `entrypoint.sh`, `config/`)
- 스택에 얹는 compose 오버레이 (`code-docker-firecrawl.yml`)
- `ootb.sh`/`migrate.sh`가 읽는 연동 메타데이터 (`ootb-manifest.env`)
- 두 네트워크를 잇는 얇은 브릿지 컨테이너 (`docker/firecrawl-proxy/`) - 이제 인증 검사는
  안 하고 그냥 전달만 합니다 (검사는 AIO 컨테이너 자신의 nginx-gate가 합니다)

레포 이름이 `firecrawl-docker`가 아니라 `code-docker-firecrawl`인 이유가 이겁니다. 여기
있는 건 code-docker 밖에서는 쓸 데가 없습니다.

## 왜 dind 안이 아니라 code-docker 옆인가

Firecrawl의 fetcher(api harness의 워커들, playwright-service)는 **공격자가 지정한
URL을 그대로 가져오는** 게 일입니다 — 그 URL이 걸어놓은 리다이렉트까지 스스로
따라갑니다. `code-docker-internal`에는 인증 없는 webmanager(포트 81)와
router-manager/VNC 경로가 같이 있어서, 그 네트워크에 닿는 fetcher 하나가 곧 SSRF 한
방으로 관리 화면 전체에 닿는 경로가 됩니다.

dind 안에 넣는 것도 여전히 고려했지만 버렸습니다 — dind 안 컨테이너는 전부 하나의 도커
데몬/브리지를 공유해서 "이 컨테이너는 나가고 저 컨테이너는 못 나가게"를 값싸게 나눌
방법이 없습니다. 그래서 이 AIO 컨테이너도 여전히 code-docker 옆에 자기만의
`internal: true` 네트워크(`firecrawl`)를 하나 만들고, 그 위에서만 돕니다.

- AIO 컨테이너(`firecrawl`)만 `netinit.provider` 라벨을 달아서 router를 거쳐 나가는
  경로를 받습니다 — 이 스택에서 실제로 외부로 나가는 건 이제 이 컨테이너 하나뿐입니다.
- `firecrawl-front`(nginx)만 `code-docker-internal`과 `firecrawl` 둘 다에 붙어서
  트래픽을 넘겨줍니다. 예전엔 이 컨테이너가 `Authorization: Bearer $FIRECRAWL_TOKEN`을
  직접 검사했지만, 이제는 AIO 컨테이너 안의 `nginx-gate` 프로그램이 그 일을 하고,
  `firecrawl-front`는 그냥 통과시키기만 합니다 (`CLAUDE.md`에 이 설계가 아직 확정이
  아니라는 TODO가 있습니다).

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

그 다음 `docker compose up -d`. 이미지를 처음부터 빌드하므로(`build: context: ..`),
`docker compose build` 가 시간이 좀 걸립니다 (node/playwright/postgres 빌드 스테이지들
+ chromium 다운로드).

## code-docker 안에서 쓰기

연동되면 `code-docker` 컨테이너 안에 `$FIRECRAWL_API_URL`(`http://firecrawl:3002`)과
`$FIRECRAWL_TOKEN`이 그대로 들어와 있습니다:

```sh
curl -s -H "Authorization: Bearer $FIRECRAWL_TOKEN" \
     -H "content-type: application/json" \
     "$FIRECRAWL_API_URL/v1/scrape" \
     -d '{"url":"https://example.com"}'
```

JS가 필요한 페이지(SPA 등)도 같은 엔드포인트로 되는지 확인하려면 무거운 페이지를
하나 던져보고, playwright 로그(`/var/log/playwright/`, AIO 컨테이너 안)에 실제
렌더링이 찍히는지 보면 됩니다 — api harness가 필요할 때 자동으로 playwright-service를
거칩니다.

크롤(`/v1/crawl`)도 됩니다 — rabbitmq 없이 postgres `LISTEN`/`NOTIFY`만으로 큐 작업
완료를 기다리는 방식(`NUQ_WAIT_MODE=listen`)으로 바뀌었는데, 상태 폴링까지 끝까지
확인해서 검증했습니다 (`CLAUDE.md`의 "Verification" 참고).

토큰 없이 호출하면 401이 돌아옵니다:

```sh
curl -s -o /dev/null -w '%{http_code}\n' "$FIRECRAWL_API_URL/v1/scrape" \
     -H "content-type: application/json" -d '{"url":"https://example.com"}'
# 401
```

## 인증: 토큰 하나가 전부입니다

**절대 비워두지 마세요.** `FIRECRAWL_TOKEN`이 비어있으면 AIO 컨테이너 자신의
nginx-gate가 모든 요청을 401로 막습니다 ("인증 꺼짐" 모드가 없습니다) — 그러니 빈
토큰은 "덜 안전"이 아니라 "아예 안 됨"입니다. `docker compose up`을 돌리는 시점에
`FIRECRAWL_TOKEN`이 정말 비어있으면 compose 자체가 에러로 멈춥니다
(`code-docker-firecrawl.yml`의 `:?` 문법).

## 제한 / 알아둘 것

- **DB 인증/`/extract`용 LLM 키를 뺀 나머지는 전부 익명 self-host 기본값입니다.**
  Supabase 연동, Autumn(과금), SearchApi 같은 건 안 붙였습니다.
- **큐 데이터(postgres)는 이름 있는 볼륨에 남습니다**
  (`code-docker-firecrawl-postgres-data`, `docker volume ls`로 찾을 수 있습니다).
  redis는 휘발성입니다(진행 중인 작업이 재시작으로 날아갈 수 있지만, 실제 큐 작업
  상태는 postgres에 있으므로 크롤/스크레이프 자체는 재시작에도 안전합니다).
- **이미지는 특정 git 태그로 고정해서 소스에서 직접 빌드합니다**
  (`FIRECRAWL_REF`, `Dockerfile` 기본값 `v2.11.408`). 업스트림이 GitHub Release를
  따로 안 끊고 커밋마다 새 semver 태그를 올리는 구조라, 주기적으로 최신 태그를 확인하고
  `FIRECRAWL_REF` 빌드 인자를 올려야 합니다.
- **호스트에 게시되는 포트가 없습니다.** 바깥에서 닿는 경로는 아예 없고, code-docker
  안의 에이전트만 `firecrawl-front`를 거쳐 씁니다.
- **컨테이너 안 포트는 게이트 포트(`FIRECRAWL_GATE_PORT`, 기본 3002) 하나만
  0.0.0.0으로 열립니다.** postgres/redis/playwright/api는 전부 컨테이너 안
  127.0.0.1만 씁니다.

## 이 레포가 code-docker에 요구하는 것

이미 code-docker 쪽에 있는 **범용 기능**만 씁니다 — 이 플러그인 전용 코드가 저쪽에
들어가 있지는 않습니다:

| 기능 | 어디 | 문서 |
|---|---|---|
| `netinit.provider`/`netinit.gateway`/`netinit.exempt-forward` 라벨 | code-docker-netinit-docker | `CLAUDE.md`의 "docker-compose topology" |
| `EXTRA_INCLUDE` + `ootb-manifest.env` | `ootb.sh`/`migrate.sh` | `docs/tips/ootb-manifest.md` |
| 서비스에 필드만 병합하는 include 병합 (`code-docker`/`code-docker-router`) | Compose 자체 | `code-docker-trilium`/`roblox-studio-docker`에서 먼저 검증됨 |
