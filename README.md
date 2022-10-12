# redis-cluster

## Cluster 구성

- cluster 관계
  - master node 간에는 샤딩으로 구성한다.
  - master - slave로 HA 구성으로 master down시 slave가 master를 백업한다.

  - node 3개 일때
 
  | master        | slave         |
  |---------------|---------------| 
  | redis_01:6010 | redis_02:6021 |
  | redis_02:6020 | redis_03:6031 |
  | redis_03:6030 | redis_01:6011 |

  - node 4개 일때
 
  | master        | slave         |
  |---------------|---------------| 
  | redis_01:6010 | redis_02:6021 |
  | redis_02:6020 | redis_03:6031 |
  | redis_03:6030 | redis_04:6041 |
  | redis_04:6040 | redis_01:6011 |

## Cluster 구성 방법

1. `cluster.conf`를 작성한다.
  - IP_DB01 ~ IP_DB0X에 node ip를 설정한다.
  - IP_DBLIST에 cluster 구성한 node 목록을 추가한다.

2. `cluster.sh create`
  - cluster.conf를 읽어 cluster를 구성한다.

3. `cluster.sh info`
  - cluster 상태를 확인한다.

4. `cluster.sh check`
  - cluster 구성 정보를 확인한다.

## Usage

```
$ cluster.sh [create|check|info|takeover IP]
```

### command

- create: cluster 구성 정보 및 데이터를 초기화 하고 새로 구성한다.
- check: cluster 구성 정보를 확인한다. (cluster nodes)
- check: cluster 상태를 확인 한다. (cluster info)
- takeover: cluster 구성을 복구한다

## Cluster 구현 순서(redis-cli 사용)

1. `flushall`
  - 모든 node에 접속해서 모든 데이터를 삭제한다.
2. `cluster reset`
  - 모든 node에 접속해서 cluster 구성을 삭제한다.
3. `cluster addslots {0..5461}`
  - 모든 master node에 접속해서 16384개의 슬롯을 node 개수로 나눠서 샤딩한다.
4. `cluster meet 192.168.10.101 6011`
  - 1번 node에 접속해서 모든 master/slave 노드/포트 정보로 cluster를 구성한다. 
  - node가 3개인 경우 샘플 

  ```
  $ redis-cli -h 192.168.10.101 -p 6010
  cluster meet 192.168.10.101 6011
  cluster meet 192.168.10.102 6020
  cluster meet 192.168.10.102 6021
  cluster meet 192.168.10.103 6030
  cluster meet 192.168.10.103 6031 
  ```

5. `cluster replicate df85034d1e2296df6177a132e48dd8a567bc38d1`
  - 모든 slave node에 접속해서 자신의 master 키로 master-slave 관계를 구성한다.
  - master 키는 `cluster node` 명령으로 확인한다.

6. `cluster nodes`
  - cluster 구성 정보를 확인한다.

7. `cluster info`
  - cluster 상태 정보를 확인한다.
