nosudo-always-passes:
  test.succeed_without_changes:
    - name: nosudo-always-passes

{%- set states = [] %}
{%- for state, enabled in salt['pillar.get']('setupify:nosudo', {}).items() %}
  {%- if enabled != False %}
  {%- do states.append(state) %}
  {%- endif %}
{%- endfor %}

{%- if states %}
include: {{ states }}
{%- endif %}
