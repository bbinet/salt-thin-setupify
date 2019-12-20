{%- set ext_sources = salt['pillar.get']('setupify:ext:sources', {}) %}
{%- if ext_sources|count > 0 %}
ext_dir:
  file.directory:
  - name: {{ grains['root'] }}/ext
clean_ext_dir:
  file.directory:
  - name: {{ grains['root'] }}/ext
  - clean: True

{%- for src_name, src in salt['pillar.get']('setupify:ext:sources', {}).items() %}
salt_master_{{ src_name }}_src_dir:
  file.directory:
  - name: {{ grains['root'] }}/ext/{{ src_name }}
  - require:
    - file: ext_dir
  - require_in:
    - file: clean_ext_dir
salt_master_{{ src_name }}_src:
  git.latest:
  - name: {{ src.address }}
  - target: {{ grains['root'] }}/ext/{{ src_name }}
  - rev: {{ src.revision|default(src.branch) }}
  - branch: {{ src.branch|default(src.revision) }}
  - force_fetch: {{ src.force_fetch|default(salt['pillar.get']('setupify:ext:force_fetch', False)) }}
  - force_reset: {{ src.force_reset|default(salt['pillar.get']('setupify:ext:force_reset', False)) }}
  - submodules: {{ src.submodules|default(salt['pillar.get']('setupify:ext:submodules', False)) }}
  - identity: {{ grains['root'] }}/.ssh/id_rsa
  - require:
    - file: ext_dir
  - require_in:
    - file: clean_ext_dir
{%- endfor %}
{%- endif %}
