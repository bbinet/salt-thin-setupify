#!/bin/bash
/usr/bin/ssh -i $( dirname "${BASH_SOURCE[0]}" )/id_rsa "$@"
