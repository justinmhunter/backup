# .bashrc

# Source global definitions
if [ -f /etc/bashrc ]; then
	. /etc/bashrc
fi

# User specific aliases and functions
alias re='screen -raAd'
alias ack='ack -a --nobinary'
alias grep='grep --color=auto'
alias vi='vim'
alias diff='diff -u'
alias addkeys='/usr/bin/ssh-add ~/.ssh/id_dsa ~/.ssh/id_rsa'
export TERM=linux
export HISTTIMEFORMAT='%F %T '
export PS1='\[\e[0;31m\]\u@\h\[\e[m\] \[\e[0;37m\]\w\[\e[m\] \[\e[0;32m\]\t\[\e[m\] \$ '

function ff() {
find . -regextype posix-egrep -type f ! -regex '.*/.svn/.*' ! -iregex '.*\.(swf|gif|jpg|png|db|gz|jar)$' -exec grep -n "$@" '{}' /dev/null \;
} 
