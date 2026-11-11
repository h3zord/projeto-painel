a:
	x || true # reprova
	x ||true; # reprova
	x || : # reprova
	trap 'limpa || true' EXIT # reprova
	all="$$(grep . || true)" # reprova
	-rm x # reprova
	@-rm x # reprova
	+-rm x # reprova
	 -rm x # reprova
	ruff check --exit-zero # reprova
	x || exit 0 # reprova
	x || return 0 # reprova
	x || echo falhou # reprova
	x \
	  || echo falhou # reprova
	x \
	  || exit 0 # reprova
	x \
	  || return 0 # reprova
	$(MAKE) -i test # reprova
.IGNORE: # reprova
