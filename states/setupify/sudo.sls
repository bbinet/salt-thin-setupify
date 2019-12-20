{%- set states = [] %}
{%- for state, enabled in salt['pillar.get']('setupify:sudo', {}).items() %}
  {%- if enabled != False %}
  {%- do states.append(state) %}
  {%- endif %}
{%- endfor %}

{%- if states %}
include: {{ states }}
{%- endif %}
