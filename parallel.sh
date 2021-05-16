#!/bin/bash

tasks_number=50
task_max_time=6
schedulers_number=5

SHARED_DIR=/dev/shm/parallel
HOURGLASSCHAR=""
#MUTEX="/run/user/$(id -u)/mutex"
MUTEX="s1"
SIGNAL="SIGUSR1"
OTHER_SIGNALS="SIGINT"

_install_sema(){
	local ret=1

	if [[ "$(command -v sema)" != "" ]]; then
		ret=0
	else
		local path=$(pwd)
		git clone https://github.com/acbits/sema
		ret=$?
		if [[ $ret -eq 0 ]]; then
			cd sema
			make
			local ret=$?
			if [[ $ret -eq 0 ]]; then
				sudo install sema /usr/local/bin/
				ret=$?
			fi
			cd $path
			rm -rf sema
		fi
	fi

	return $ret
}

_int(){
	echo "_int: Got interrupt (signal $1) from a scheduler: jobs are done. Initializing ending sequence..."
	exit_signal=1
}
trap "_int $SIGNAL" $SIGNAL
for signal in $(echo "$OTHER_SIGNALS"); do
	trap "_int $signal" $signal
done

__hourglass(){
	if [[ "$HOURGLASSCHAR" = "" ]]; then
		HOURGLASSCHAR="|"
	elif [[ "$HOURGLASSCHAR" = "|" ]]; then
		HOURGLASSCHAR="/"
	elif [[ "$HOURGLASSCHAR" = "/" ]]; then
		HOURGLASSCHAR="-"
	elif [[ "$HOURGLASSCHAR" = "-" ]]; then
		HOURGLASSCHAR="\\"
	elif [[ "$HOURGLASSCHAR" = "\\" ]]; then
		HOURGLASSCHAR="|"
	fi

	echo -en "\r$HOURGLASSCHAR $1"
}

_clear_mutex(){
	local mutex="$1"
	#rm $mutex >/dev/null 2>&1
	sema -d $mutex >/dev/null 2>&1
}

_acquire_mutex(){
	local mutex="$1"
	#tail --follow --lines=0 "$mutex" 2>/dev/null | head -n1 >/dev/null
	#echo > $mutex
	if [[ "$(sema -v $mutex 2>/dev/null)" = "" ]]; then
		sema -c $mutex 1
	fi
	sema -w $mutex
}

_release_mutex(){
	local mutex="$1"
	#echo > $mutex
	sema -r $mutex
}

_serialize(){
	local result=""

	while [[ $# -gt 0 ]]; do
		if [[ "$result" != "" ]]; then
			result+="
"
		fi
		result+=$(printf '%s' "$1" | base64)
		shift
	done

	echo "$result"
}

_unserialize(){
	local result=()

	local ser_var="$1"
	shift
	local return_var=""
	local item

	if [[ "$1" != "" ]]; then
		return_var="$1"
		shift
		while IFS=$'\n' read -r line; do
			item=$(echo "$line" | base64 -d)
			result+=("$item")
		done <<< "$(echo -e "$ser_var")"
	fi

	eval "$return_var=()"
	for (( i=0; i<${#result[@]}; ++i )); do
		eval "$return_var[$i]='${result[i]}'"
	done
}

_set_shared(){
	local result=1

	local var="$1"
	local content=()
	local ser_content
	local ret

	if [[ "$var" != "" ]]; then
		shift
		ret=0

		if [[ $# -gt 0 ]]; then
			if [[ ! -d $SHARED_DIR ]]; then
				mkdir -p $SHARED_DIR
				ret=$?
			fi

			if [[ $ret -eq 0 && ! -f $SHARED_DIR/$var ]]; then
				touch $SHARED_DIR/$var
				ret=$?
			fi

			if [[ $ret -eq 0 ]]; then
				while [[ $# -gt 0 ]]; do
					content+=("$1")
					shift
				done

				if [[ ${#content[@]} -gt 0 ]]; then
					ser_content=$(_serialize ${content[@]})
					ret=$?
					if [[ $ret -eq 0 ]]; then
						echo -e "$ser_content" > $SHARED_DIR/$var
						ret=$?
					fi
				fi
			fi
		else
			_delete_shared "$var"
			ret=$?
		fi

		if [[ $ret -eq 0 ]]; then
			result=$ret
		fi
	fi

	return $result
}

_get_shared(){
	local result=1

	local var="$1"
	local return_var="$2"
	local ser_content=""

	if [[ "$var" != "" && "$return_var" != "" ]]; then
		if [[ -f $SHARED_DIR/$var ]]; then
			ser_content=$(cat $SHARED_DIR/$var 2>/dev/null)
		fi

		if [[ "$ser_content" != "" ]]; then
			_unserialize "$ser_content" "$return_var"
			result=$?
		else
			eval "$return_var=()"
		fi
	fi

	return $result
}

_delete_shared(){
	local result=1

	local var="$1"
	local ret=0

	if [[ -f $SHARED_DIR/$var ]]; then
		rm $SHARED_DIR/$var
		ret=$?
	elif [[ -d $SHARED_DIR/$var ]]; then
		if [[ "$(realpath $SHARED_DIR/$var)" != "/dev/shm" && "$(realpath $SHARED_DIR/$var)" != "/tmp" ]]; then
			rm -rf $SHARED_DIR/$var
			ret=$?
		fi
	elif [[ -d $var ]]; then
		if [[ "$(echo "$var" | grep "^$SHARED_DIR")" != "" ]]; then
			if [[ "$(realpath $var)" = "$(realpath $SHARED_DIR)" && "$(realpath $var)" != "/dev/shm" && "$(realpath $var)" != "/tmp" ]]; then
				rm -rf $var
				ret=$?
			fi
		fi
	fi

	if [[ $ret -eq 0 ]]; then
		result=$ret
	fi

	return $result
}

process1(){
	for i in $(seq 1 5); do
		echo "p1: Acquiring mutex..."
		_acquire_mutex $MUTEX
		echo "p1: I have the mutex!"
		sleep $(((RANDOM % $task_max_time) + 1))
		echo "p1: Releasing mutex..."
		_release_mutex $MUTEX
		echo "p1: Mutex released!"
	done
}

process2(){
	for i in $(seq 1 5); do
		echo "p2: Acquiring mutex..."
		_acquire_mutex $MUTEX
		echo "p2: I have the mutex!"
		sleep $(((RANDOM % $task_max_time) + 1))
		echo "p2: Releasing mutex..."
		_release_mutex $MUTEX
		echo "p2: Mutex released!"
	done
}

task(){
	local worker="$1"
	mypid=$BASHPID
	parentpid=$$
	#echo "		worker$worker: $(date +'%Y%m%d%H%M%S'): Begins task ($mypid) at $(date)"
	sleep $(((RANDOM % $task_max_time) + 1))
	#echo "		worker$worker: $(date +'%Y%m%d%H%M%S'): Ends task ($mypid) at $(date)"
}

scheduler(){
	local myname="$1"
	local parentpid=$$
	local myschedulerid=$(echo $myname | cut -c3-)

	local pid_check
	local change=0
	local count=0
	local tmp_pids=()
	local PIDS

	local all_done=0
	while [[ $all_done -ne 1 ]]; do
		sleep 0.1
		change=0
		count=0
		_acquire_mutex $MUTEX
			tmp_pids=()
			_get_shared 'PIDS' 'PIDS'
			for pid in "${PIDS[@]}"; do
				pscheck=$(ps -p "$pid" | grep -v 'CMD')
				if [[ "$pscheck" = "" ]]; then
					change=1
					echo "	$myname: PID $pid is done!"
				else
					tmp_pids+=($pid)
				fi
				count=$((count + 1))
			done

			if [[ $change -eq 1 ]]; then
				_set_shared 'PIDS' ${tmp_pids[@]}
			fi

			if [[ ${#tmp_pids[@]} -eq 0 ]]; then
				_release_mutex $MUTEX
				break
			fi
		_release_mutex $MUTEX
	done

	if [[ $change -eq 1 && ${#tmp_pids[@]} -eq 0 ]]; then
		echo "	$myname: All tasks are done. As I witnessed the last task ending, I'm sending signal $SIGNAL to parent $parentpid"
		kill -s $SIGNAL $parentpid
	fi

	echo "	$myname: I'm done"
}

_install_sema
if [[ $? -ne 0 ]]; then
	echo "Can't install sema!"
	exit 1
fi




exit_signal=0

_clear_mutex $MUTEX
_acquire_mutex $MUTEX
	_delete_shared $SHARED_DIR
	_set_shared 'PIDS'
_release_mutex $MUTEX

task_count=0
while [[ $task_count -lt $tasks_number && $exit_signal -ne 1 ]]; do
	task "wk$task_count" &
	pid=$!
	_acquire_mutex $MUTEX
		_get_shared 'PIDS' 'PIDS'
		PIDS+=($pid)
		_set_shared 'PIDS' ${PIDS[@]}
	_release_mutex $MUTEX
	echo "main: Just launched worker $task_count ($pid)"
	task_count=$((task_count + 1))
done

scheduler_count=0
while [[ $scheduler_count -lt $schedulers_number && $exit_signal -ne 1 ]]; do
	scheduler "scheduler$scheduler_count" &
	sleep 0.1
	echo "main: Just launched scheduler $scheduler_count ($pid)"
	scheduler_count=$((scheduler_count + 1))
done

while [[ $exit_signal -ne 1 ]]; do
	__hourglass
	sleep 0.1
done

echo "main: Ending sequence launched. Waiting for last scheduler processes to end..."
wait
echo "main: All tasks done!"

_delete_shared $SHARED_DIR
_clear_mutex $MUTEX
exit 0
