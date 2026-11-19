/* usage: ucode acct.uc init | save | prune <mac>... */
'use strict';

import { read_store, save, prune } from 'bypass.acct';

const cmd = shift(ARGV);

if (cmd == 'init')
	read_store();
else if (cmd == 'save')
	save();
else if (cmd == 'prune')
	prune(ARGV);
