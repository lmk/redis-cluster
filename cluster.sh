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
DB_CNT="${#IP_DBLIST[@]}"

scriptName=${0##*/}

# 함수 정의
function print_help(){
  echo "Usage $scriptName [create|check|info|takeover IP]" 
}

function reset_redis(){
  for ip in ${IP_DBLIST[@]}; do
    echo -n -e "flushall $ip:$P_PORT "
    result=`redis-cli -h $ip -p $P_PORT flushall`
    if [ "OK" != "$result" ]; then
      printf "\033[1;31m $result \r\n\033[0m";
    else 
      printf "\033[1;32m $result \r\n\033[0m";
    fi 

    echo -n -e "cluster reset $ip:$P_PORT "
    result=`redis-cli -h $ip -p $P_PORT cluster reset`
    if [ "OK" != "$result" ]; then
      printf "\033[1;31m $result \r\n\033[0m";
      exit;
    else 
      printf "\033[1;32m $result \r\n\033[0m";
    fi 

    echo -n -e "cluster reset $ip:$C_PORT "
    result=`redis-cli -h $ip -p $C_PORT cluster reset`
    if [ "OK" != "$result" ]; then
      printf "\033[1;31m $result \r\n\033[0m";
      exit;
    else 
      printf "\033[1;32m $result \r\n\033[0m";
    fi
  done
}

function shard_redis(){
  echo -n -e "$SKY\n===> $HOSTNAME:$IP_DB01 shard slot $DB_CNT redis $PARENTSTR("
  slots=()
  offset=$(( 16383 / $DB_CNT ))
  sno=0
  eno=0
  i=0
  for ip in ${IP_DBLIST[@]}; do
    i=$(( $i + 1 ))
    if [ "$i" == "$DB_CNT" ]; then
      eno=16383
    else
      eno=$(( $sno + $offset ))
    fi

    echo -n -e "$sno-$eno"
    if [ "$i" != "$DB_CNT" ]; then
      echo -n -e ", "
    fi

    slots=("${slots[@]} {$sno..$eno}")
    sno=$(( $eno + 1 ))
  done
  echo -e ")$FREE"

  i=0
  for slot in ${slots[@]}; do
    ip=${IP_DBLIST[$i]}
    echo "CLUSTER ADDSLOTS $ip $P_PORT $slot"
    i=$((i+1))

    result=`eval "redis-cli" "-h" $ip "-p" $P_PORT "cluster" "addslots" $slot`
  done

  echo -e "$SKY""===> Done $FREE"
}

function addnode_redis(){
  echo -n -e "$SKY\n===> $HOSTNAME:$IP_DB01 cluster addnode"

  for ip in ${IP_DBLIST[@]}; do
    printf 'CLUSTER MEET %s %s\r\n' "$ip" "$C_PORT"
    result=`redis-cli -h $IP_DB01 -p $P_PORT cluster meet $ip $C_PORT`
    if [ "OK" != "$result" ]; then printf "\033[1;31m $result \r\n033[0m"; exit; fi

    printf 'CLUSTER MEET %s %s\r\n' "$ip" "$P_PORT"
    result=`redis-cli -h $IP_DB01 -p $P_PORT cluster meet $ip $P_PORT`
    if [ "OK" != "$result" ]; then printf "\033[1;31m $result \r\n033[0m"; exit; fi
  done

  count=0
  while [ ${count} -le 20 ]; do
    sleep 1
    cluster=$(redis-cli -c -h $IP_DB01 -p $P_PORT cluster nodes | wc -l)
    handshake=$(redis-cli -c -h $IP_DB01 -p $P_PORT cluster nodes | grep -v $PARENTSTR | grep -v $CHILDSTR | wc -l)
    if [ $handshake -eq 0 ]; then
      break
    fi
    echo "cluster($cluster):handshake($handshake)...$count"
    count=$((count+1))
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

  #set -x

  i=0
  for ip in ${IP_DBLIST[@]}; do
    i=$(( $i + 1 ))
    if [ "$i" == "$DB_CNT" ]; then
      echo "$PARENTSTR($ip:$P_PORT)'s $CHILDSTR(${IP_DBLIST[0]}:$C_PORT)"
      result=`redis-cli -c -h ${IP_DBLIST[0]} -p $C_PORT CLUSTER REPLICATE $(redis-cli -c -h $ip -p $P_PORT CLUSTER NODES | grep "$ip:$P_PORT" | awk '{print $1}')`
      if [ "OK" != "$result" ]; then printf "\033[1;31m $result \r\n033[0m"; exit; fi
    else
      echo "$PARENTSTR($ip:$P_PORT)'s $CHILDSTR(${IP_DBLIST[$i]}:$C_PORT)"
      result=`redis-cli -c -h ${IP_DBLIST[$i]} -p $C_PORT CLUSTER REPLICATE $(redis-cli -c -h $ip -p $P_PORT CLUSTER NODES | grep "$ip:$P_PORT" | awk '{print $1}')`
      if [ "OK" != "$result" ]; then printf "\033[1;31m $result \r\n033[0m"; exit; fi
    fi
    
    redis-cli -c -h $IP_DB01 -p $P_PORT cluster nodes
  done

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
  for IP in ${IP_DBLIST[@]} $IP_LOCAL; do
    nc_result=1
    for PORT in $P_PORT $C_PORT; do
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
        for nodeIP in ${IP_DBLIST[@]}
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

  for IP in ${IP_DBLIST[@]}; do
    if [ "$IP" == "$1" ]; then
      redis-cli -c -h $IP -p $C_PORT CLUSTER FAILOVER
      echo -e "$SKY ===> Done $FREE"
      return 0
    fi 
  done

  echo -e "$RED ===> Fail $FREE"
}

function takeover(){
  echo -e "$SKY\n===> takeover $1 $FREE"

  for IP in ${IP_DBLIST[@]}; do
    if [ "$IP" == "$1" ]; then
      redis-cli -c -h $IP -p $P_PORT CLUSTER FAILOVER
      echo -e "$SKY ===> Done $FREE"
      return 0
    fi 
  done

  echo -e "$RED ===> Fail $FREE"
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
  reset_redis
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
