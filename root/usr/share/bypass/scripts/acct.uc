/* usage: ucode acct.uc init | save | bank | prune <mac>... */
'use strict';

import { read_store, save, prune, bank_rules } from 'bypass.acct';

const cmd = shift(ARGV);

if (cmd == 'init')
	read_store();
else if (cmd == 'save') {
	save();
	bank_rules();
}
else if (cmd == 'bank')
	bank_rules();
else if (cmd == 'prune')
	prune(ARGV);
