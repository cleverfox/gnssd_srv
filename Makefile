INCLUDE=-pa deps/*/ebin \
	-pa ebin

all:
	./rebar compile
run:
	rlwrap --always-readline erl $(INCLUDE) \
	-kernel inetrc '"./erl_inetrc"' \
	-boot start_sasl -name gnss_srv -config gnss_srv.config -s lager start -s gnss_srv start -s sync go
deploy:
	erl -detached -noshell -noinput $(INCLUDE) \
	-kernel inetrc '"./erl_inetrc"' \
	-boot start_sasl -name gnss_srv -config gnss_srv.config -s lager start -s gnss_srv start -s sync go
attach:
	rlwrap --always-readline erl -name con`jot -r 1 0 100` -hidden -remsh gnss_srv@`hostname`
stop:
	echo 'halt().' | erl -name con`jot -r 1 0 100` -remsh gnss_srv@`hostname`
