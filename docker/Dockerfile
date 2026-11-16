FROM postgres:15-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-15-rdkit \
 && sed -i -e "/COMMUTATOR = '='/d" -e "/NEGATOR = '<>'/d" /usr/share/postgresql/15/extension/rdkit--*.sql \
 && rm -rf /var/lib/apt/lists/*
