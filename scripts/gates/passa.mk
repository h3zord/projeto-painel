a:
	run || true_ou_falso
	compose down || down=$$?
	clean || { c=$$?; }
	@grep -E x y
	rm -rf x
	[ -f x ] || exit 0
	[ -z "$$x" ] || echo aviso
	x || exit 10
	x || { echo erro >&2; exit 1; }
	docker run -it img
