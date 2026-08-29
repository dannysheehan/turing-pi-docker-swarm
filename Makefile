.PHONY: setup validate versions inventory syntax lint scripts secrets

UV_RUN := uv run --frozen

setup:
	uv sync --frozen
	$(UV_RUN) ansible-galaxy collection install \
		--collections-path collections \
		-r collections/requirements.yml

validate: versions inventory syntax lint scripts secrets

versions:
	@$(UV_RUN) python -c 'import importlib.metadata as m, pathlib, platform, tomllib; p = tomllib.loads(pathlib.Path("pyproject.toml").read_text()); expected = dict(x.split("==", 1) for x in p["project"]["dependencies"]); assert platform.python_version() == pathlib.Path(".python-version").read_text().strip(); assert all(m.version(k) == v for k, v in expected.items())'
	@$(UV_RUN) ansible-galaxy collection list ansible.posix | grep -Eq '^ansible\.posix[[:space:]]+2\.2\.2([[:space:]]|$$)'
	@$(UV_RUN) ansible-galaxy collection list community.general | grep -Eq '^community\.general[[:space:]]+13\.3\.0([[:space:]]|$$)'
	@$(UV_RUN) ansible-galaxy collection list community.library_inventory_filtering_v1 | grep -Eq '^community\.library_inventory_filtering_v1[[:space:]]+1\.1\.5([[:space:]]|$$)'

inventory:
	$(UV_RUN) ansible-inventory --graph >/dev/null

syntax:
	@for playbook in $$(find . -maxdepth 1 -name '*.yml' ! -name 'hosts.yml' -print | sort); do \
		$(UV_RUN) ansible-playbook --syntax-check "$$playbook"; \
	done

lint:
	$(UV_RUN) ansible-lint --offline

scripts:
	$(UV_RUN) python -m py_compile scripts/check-secrets

secrets:
	$(UV_RUN) python scripts/check-secrets


