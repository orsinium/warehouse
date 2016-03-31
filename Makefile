BINDIR = $(PWD)/.state/env/bin
PR := $(shell echo "$${TRAVIS_PULL_REQUEST:-false}")
BRANCH := $(shell echo "$${TRAVIS_BRANCH:-master}")

define DEPCHECKER
import sys
import collections

from pip.req import parse_requirements

Dependency = collections.namedtuple("Dependency", ["name", "specifier"])

left, right = sys.argv[1:3]
left_reqs = {
	Dependency(name=d.name, specifier=d.specifier)
	for d in parse_requirements(left, session=object())
	if d.name != "setuptools"
}
right_reqs = {
	Dependency(name=d.name, specifier=d.specifier)
	for d in parse_requirements(right, session=object())
	if d.name != "setuptools"
}

extra_in_left = left_reqs - right_reqs
extra_in_right = right_reqs - left_reqs

if extra_in_left:
	for dep in sorted(extra_in_left, key=lambda x: x.name):
		print("- {}{}".format(dep.name, dep.specifier))

if extra_in_right:
	for dep in sorted(extra_in_right, key=lambda x: x.name):
		print("+ {}{}".format(dep.name, dep.specifier))

if extra_in_left or extra_in_right:
	sys.exit(1)
endef

default:
	@echo "Must call a specific subcommand"
	@exit 1

.state/env/pyvenv.cfg: requirements/dev.txt requirements/docs.txt requirements/lint.txt
	# Create our Python 3.5 virtual environment
	rm -rf .state/env
	python3.5 -m venv .state/env

	# install/upgrade general requirements
	.state/env/bin/python -m pip install --upgrade pip setuptools wheel

	# install various types of requirements
	.state/env/bin/python -m pip install -r requirements/dev.txt
	.state/env/bin/python -m pip install -r requirements/docs.txt
	.state/env/bin/python -m pip install -r requirements/lint.txt

.state/docker-build: Dockerfile package.json requirements/main.txt requirements/deploy.txt
	# Build our docker containers for this project.
	docker-compose build

	# Mark the state so we don't rebuild this needlessly.
	mkdir -p .state
	touch .state/docker-build

build:
	docker-compose build

	# Mark this state so that the other target will known it's recently been
	# rebuilt.
	mkdir -p .state
	touch .state/docker-build

serve: .state/docker-build
	RECAPTCHA_SITE_KEY=$(RECAPTCHA_SITE_KEY) RECAPTCHA_SECRET_KEY=$(RECAPTCHA_SECRET_KEY) docker-compose up

debug: .state/docker-build
	RECAPTCHA_SITE_KEY=$(RECAPTCHA_SITE_KEY) RECAPTCHA_SECRET_KEY=$(RECAPTCHA_SECRET_KEY) docker-compose run --service-ports web

tests:
	docker-compose run web env -i ENCODING="C.UTF-8" bin/tests --dbfixtures-config tests/dbfixtures.conf $(T) $(TESTARGS)

lint: .state/env/pyvenv.cfg
	$(BINDIR)/flake8 .
	$(BINDIR)/doc8 --allow-long-titles README.rst CONTRIBUTING.rst docs/ --ignore-path docs/_build/
	$(BINDIR)/html_lint.py --disable=optional_tag `find ./warehouse/templates -path ./warehouse/templates/legacy -prune -o -name '*.html' -print`


docs: .state/env/pyvenv.cfg
	$(MAKE) -C docs/ doctest SPHINXOPTS="-W" SPHINXBUILD="$(BINDIR)/sphinx-build"
	$(MAKE) -C docs/ html SPHINXOPTS="-W" SPHINXBUILD="$(BINDIR)/sphinx-build"

export DEPCHECKER
deps: .state/env/pyvenv.cfg
	$(eval TMPDIR := $(shell mktemp -d))
	$(BINDIR)/pip-compile --no-annotate --no-header --upgrade -o $(TMPDIR)/deploy.txt requirements/deploy.in > /dev/null
	$(BINDIR)/pip-compile --no-annotate --no-header --upgrade -o $(TMPDIR)/main.txt requirements/main.in > /dev/null
	echo "$$DEPCHECKER" | python - $(TMPDIR)/deploy.txt requirements/deploy.txt
	echo "$$DEPCHECKER" | python - $(TMPDIR)/main.txt requirements/main.txt
	rm -r $(TMPDIR)

travis-deps:
ifneq ($(PR), false)
	git fetch origin $(BRANCH):refs/remotes/origin/$(BRANCH)
	git diff --name-only $(BRANCH) | grep '^requirements/' || exit 0 && $(MAKE) deps
endif

initdb:
	docker-compose run web psql -h db -d postgres -U postgres -c "CREATE DATABASE warehouse ENCODING 'UTF8'"
	xz -d -k dev/example.sql.xz
	docker-compose run web psql -h db -d warehouse -U postgres -v ON_ERROR_STOP=1 -1 -f dev/example.sql
	rm dev/example.sql
	docker-compose run web python -m warehouse db upgrade head
	$(MAKE) reindex

reindex:
	docker-compose run web python -m warehouse search reindex

shell:
	docker-compose run web python -m warehouse shell

clean:
	rm -rf warehouse/static/components
	rm -rf warehouse/static/dist

purge: clean
	rm -rf .state
	docker-compose rm --force


.PHONY: default build serve initdb shell tests docs deps travis-deps clean purge update-requirements debug
