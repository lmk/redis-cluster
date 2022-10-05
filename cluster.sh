#!/bin/bash

# text color
SKY="\x1b[36m"
PINK="\x1b[35m"
RED="\x1b[31m"
GREEN="\x1b[32m"
YELLOW="\x1b[33m"
BLUE="\x1b[34m"
FREE="\x1b[0m"

PARENTSTR="master"
CHILDSTR="slave"

source ./cluster.conf

scriptName=${0##*/}

# 함수 정의
function print_help(){
  echo "Usage $scriptName [create|check|info|takeover IP]" 
}

function shard_redis(){
  echo -e "$SKY\n===> $HOSTNAME:$IP_DB01 shard slot 4 redis $PARENTSTR(0-5461, 5462-10922, 10923916383)$FREE"
  echo "CLUSTER ADDSLOTS $IP_DB01 $P_PORT {0..5461}"
  result=$(printf "CLUSTER RESET" | redis-cli -h $IP_DB01 -p $P_PORT); 
  if [ "OK" != "$result" ]; then  printf "\033[1;31m$result\r\n\033[0m"; fi
  result=$(redis-cli -h $IP_DB01 -p $P_PORT cluster addslots {0..5461}); 
  if [ "OK" != "$result" ]; then  printf "\033[1;31m$result\r\n\033[0m"; fi
  echo "CLUSTER ADDSLOTS $IP_DB02 $P_PORT {5462..10922}"
  result=$(printf "CLUSTER RESET" | redis-cli -h $IP_DB02 -p $P_PORT); 
  if [ "OK" != "$result" ]; then  printf "\033[1;31m$result\r\n\033[0m"; fi
  result=$(redis-cli -h $IP_DB02 -p $P_PORT cluster addslots {5462..10922}); 
  if [ "OK" != "$result" ]; then  printf "\033[1;31m$result\r\n\033[0m"; fi
  echo "CLUSTER ADDSLOTS $IP_DB03 $P_PORT {10923..16383}"
  result=$(printf "CLUSTER RESET" | redis-cli -h $IP_DB03 -p $P_PORT); 
  if [ "OK" != "$result" ]; then  printf "\033[1;31m$result\r\n\033[0m"; fi
  result=$(redis-cli -h $IP_DB03 -p $P_PORT cluster addslots {10923..16383}); 
  if [ "OK" != "$result" ]; then  printf "\033[1;31m$result\r\n\033[0m"; fi
}

function addnode_redis(){
  echo -e "$SKY\n===> $HOSTNAME:$IP_DB01 cluster addnode$FREE"

  printf "\
CLUSTER MEET $IP_DB01 $C_PORT\r\n\
CLUSTER MEET $IP_DB02 $P_PORT\r\n\
CLUSTER MEET $IP_DB02 $C_PORT\r\n\
CLUSTER MEET $IP_DB03 $P_PORT\r\n\
CLUSTER MEET $IP_DB03 $C_PORT\r\n\
redis-cli -h $IP_DB01 -p $P_PORT\r\n"

  (
    printf "\
CLUSTER MEET $IP_DB01 $C_PORT\r\n\
CLUSTER MEET $IP_DB02 $P_PORT\r\n\
CLUSTER MEET $IP_DB02 $C_PORT\r\n\
CLUSTER MEET $IP_DB03 $P_PORT\r\n\
CLUSTER MEET $IP_DB03 $C_PORT\r\n"
    sleep 1;) | result=$(redis-cli -h $IP_DB01 -p $P_PORT) echo $result | xargs

  count=0
  while [ ${count} -le 20 ]; do
    cluster=$(redis-cli -c -h $IP_DB01 -p $P_PORT cluster nodes | wc -l)
    handshake=$(redis-cli -c -h $IP_DB01 -p $P_PORT cluster nodes | grep -v $PARENTSTR | grep -v $CHILDSTR | wc -l)
    if [ $handshake -eq 0 ]; then
      break
    fi
    echo "cluster($cluster):handshake($handshake)...$count"
    count=$((count+1))
    sleep 1
  done

  echo "cluster($cluster):handshake($handshake)...$count"
  redis-cli -c -h $IP_DB01 -p $P_PORT cluster nodes
  if [ $count -eq 20 ]; then
    echo -e "$RED""FAIL$FREE"
    exit -1
  fi

  echo -e "$SKY""===> Done$FREE"
}

function cluster_del(){
  rm -f ~/cluster/*/data/*.*  ~/cluster/*/conf/nodes.conf ~/logs/*
}

function cluster_redis(){
  echo -e "$SKY\n===> $HOSTNAME:$IP_DB01 cluster $PARENTSTR-$CHILDSTR $FREE"

  echo "$PARENTSTR($IP_DB01:$P_PORT)'s $CHILDSTR($IP_DB02:$C_PORT)"
  redis-cli -c -h $IP_DB02 -p $C_PORT CLUSTER REPLICATE $(redis-cli -c -h $IP_DB01 -p $P_PORT CLUSTER NODES | grep "$IP_DB01:$P_PORT" | awk '{print $1}')

  echo "$PARENTSTR($IP_DB02:$P_PORT)'s $CHILDSTR($IP_DB03:$C_PORT)"
  redis-cli -c -h $IP_DB03 -p $C_PORT CLUSTER REPLICATE $(redis-cli -c -h $IP_DB02 -p $P_PORT cluster nodes | grep "$IP_DB02:$P_PORT" | awk '{print $1}')

  echo "$PARENTSTR($IP_DB03:$P_PORT)'s $CHILDSTR($IP_DB01:$C_PORT)"
  redis-cli -c -h $IP_DB01 -p $C_PORT CLUSTER REPLICATE $(redis-cli -c -h $IP_DB03 -p $P_PORT cluster nodes | grep "$IP_DB03:$P_PORT" | awk '{print $1}')

  count=0
  while [ ${count} -le 20 ]; do
    parent=$(redis-cli -c -h $IP_DB01 -p $P_PORT cluster nodes | grep $PARENTSTR | wc -l)
    child=$(redis-cli -c -h $IP_DB01 -p $P_PORT cluster nodes | grep $CHILDSTR | wc -l) 
    if [ $parent -eq $child ]; then
      break
    fi
    echo "$PARENTSTR($parent):$CHILDSTR($child)...$count"
    count=$((count+1))
    sleep 1
  done

  echo "$PARENTSTR($parent):$CHILDSTR($child)...$count"
  if [ $count -eq 20 ]; then
    echo -e "$RED""FAIL$FREE"
    exit
  fi

  echo -e "$SKY""===> Done$FREE"
}

clusterInfo=""
node=""
function IsParent(){
  node=$(echo "$clusterInfo"| grep $1:$2)

  isParent=$(echo "$node" | grep fail |  awk '{if(0 != index($3,"fail")) print 3; else print 0}')
    if [ -z "$isParent" -o "0" == "$isParent" ]; then
      isParent=$(echo "$node" | grep master |  awk '{if("connected"==""$8) print 1; else print 0}')
    fi

    if [ -z "$isParent" -o "0" == "$isParent" ]; then
    isParent=$(echo "$node" | grep slave |  awk '{if("connected"==""$8) print 2; else print 0}')
    fi	

  return $isParent
}

function check_redis(){
  echo -e "$SKY\n===> $HOSTNAME:$IP_DB01 check cluster$FREE"

  local nc_result

  for IP in $IP_LOCAL $IP_DB01 $IP_DB02 $IP_DB03
  do
    nc_result=1
    for PORT in $P_PORT $C_PORT
    do
      nc_result=`timeout 0.3 bash -c "cat < /dev/null > /dev/tcp/$IP/$PORT"; echo $?`
      if [ "$nc_result" = 0 ]; then
        echo "CONNECT IP:$IP PORT:$PORT"
        clusterInfo=$(redis-cli -c -h $IP -p $PORT cluster nodes)
        cluster=$(echo "$clusterInfo" | wc -l)
        clusterTotal=$(echo "$clusterInfo" | awk '{print $8}' | wc -l)
        ParentCnt=$(echo "$clusterInfo" | awk '{if("connected"==$8) print $3}' | grep -v fail |grep master |  wc -l)
        ParentTotal=$(echo "$clusterInfo" | awk '{print $3}' | grep master |  wc -l)
        ChildCnt=$(echo "$clusterInfo" | awk '{if("connected"==$8) print $3}' | grep -v fail | grep slave |  wc -l)
        ChildTotal=$(echo "$clusterInfo" | awk '{print $3}' | grep slave |  wc -l)

        clusterInfo=$(echo "$clusterInfo" | awk '{print $2,$1,$3,$4,$5,$6,$7,$8,$9}'| sort)
            
        index=0
        for nodeIP in $IP_DB01 $IP_DB02 $IP_DB03
        do
          for nodePort in $P_PORT $C_PORT
          do
            IsParent $nodeIP $nodePort
            
            if [ "1" ==  "$isParent" ]; then
              echo -e "$GREEN$(echo $node)$FREE"
            elif [ "3" == "$isParent" ]; then
              echo -e "$RED$(echo $node)$FREE"
            else 
              echo -e "$(echo $node)"
            fi
          done
        done

        if [ "$ParentCnt" != "$ParentTotal" ]; then
          echo -e "Cluster [$RED"Fail"$FREE] total:$RED$cluster$FREE $PARENTSTR:$RED$ParentCnt$FREE $CHILDSTR:$RED$ChildCnt$FREE"
        elif [ "$ChildCnt" != "$ChildTotal" ];then
          echo -e "Cluster [$RED"Fail"$FREE] total:$RED$cluster$FREE $PARENTSTR:$RED$ParentCnt$FREE $CHILDSTR:$RED$ChildCnt$FREE"
        else
          echo -e "Cluster:[$GREEN"OK"$FREE] total:$GREEN$cluster$FREE $PARENTSTR:$GREEN$ParentCnt$FREE $CHILDSTR:$GREEN$ChildCnt$FREE"
        fi
        break
      fi
    done

    if [ "$nc_result" = 0 ]; then
        break
    fi
  done
}

function cluster_info(){
  result=$(redis-cli -c -p $P_PORT cluster info | sed 's/cluster_state:fail/cluster_state:\\033\[1;31mfail\\033\[0m/')
  result=$(echo -e "$result" | sed 's/cluster_state:ok/cluster_state:\\033\[1;32mok\\033\[0m/')

  echo -e "$result"
}


function failover(){
  echo -e "$SKY\n===> failover $1 $FREE"

  if [ "$IP_DB01" == "$1" ]; then
    redis-cli -c -h $IP_DB01 -p $C_PORT CLUSTER FAILOVER
  elif [ "$IP_DB02" == "$1" ]; then
    redis-cli -c -h $IP_DB02 -p $C_PORT CLUSTER FAILOVER
  else
    redis-cli -c -h $IP_DB03 -p $C_PORT CLUSTER FAILOVER
  fi

  echo -e "$SKY""===> Done $FREE"
}

function takeover(){
  echo -e "$SKY\n===> takeover $1 $FREE"
  if [ "$IP_DB01" == "$1" ]; then
      redis-cli -c -h $IP_DB01 -p $P_PORT CLUSTER FAILOVER
  elif [ "$IP_DB02" == "$1" ]; then
      redis-cli -c -h $IP_DB02 -p $P_PORT CLUSTER FAILOVER
  else
      redis-cli -c -h $IP_DB03 -p $P_PORT CLUSTER FAILOVER
  fi

  echo -e "$SKY""===> Done$FREE"
}


if [ $# -lt 1 ]; then
  print_help
  exit
fi

if [ "create" = $1 ]; then
  echo ""
  echo -e "$RED Delete old data & Create new data. $FREE"
  echo ""
  read -p " Continue? (yes|no):" response
 
  if [ "yes" != "$response" ]; then
   echo ""
   echo "Cancle create."
   exit
  fi

  shard_redis
  addnode_redis 
  cluster_redis 
elif [ "check" = $1 ]; then
 check_redis
elif [ "takeover" == $1 ]; then
	takeover $2
elif [ "failover" == $1 ]; then
	failover $2
elif [ "info" = $1 ]; then
  cluster_info
elif [ "delete" = $1 ]; then
  echo ""
  echo -e "$RED Delete cluster files. $FREE"
  echo ""
  read -p " Continue? (yes|no):" response

  if [ "yes" != "$response" ]; then
    echo ""
    echo "Cancle delete."
    exit
  fi

  cluster_del
else
	print_help
fi
