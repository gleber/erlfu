REBAR=$(shell which rebar || echo ./rebar)

all: $(REBAR)
	$(REBAR) get-deps compile

tests:  $(REBAR)
	$(REBAR) eunit skip_deps=true

sh: all
	erl -name f$$$$ -pa .eunit/ -pa ebin/ -pa deps/*/ebin -eval 'erlfu:start(), shell_default:m(future_tests), shell_default:m(future).'

test: tests

clean:
	$(REBAR) clean skip_deps=true

# Detect or download rebar

REBAR_URL=http://cloud.github.com/downloads/basho/rebar/rebar
./rebar:
	erl -noshell -s inets -s ssl \
		-eval 'httpc:request(get, {"$(REBAR_URL)", []}, [], [{stream, "./rebar"}])' \
		-s init stop
	chmod +x ./rebar

distclean:
	rm -f ./rebar
