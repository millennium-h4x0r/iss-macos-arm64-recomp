/* Placeholder for the PS4 user range [0x7000000000, 0xe000000000) (main.c USER_MIN/USER_MAX).
 * From macOS 27, malloc reserves a randomized ~12 GiB block inside that range during libSystem
 * initialization, before any constructor of ours runs. A zero-fill segment linked there
 * (build.sh: -segaddr __TLGUSER 0x7000000000) is mapped by the kernel with the executable, so
 * malloc goes elsewhere; reserve_guest_ranges() unmaps it and reserves the range as before.
 * The executable slides with ASLR (up to a few hundred MiB), so the segment may start a little
 * above USER_MIN; that gap is reserved like the rest. */
.zerofill __TLGUSER,__user,_tlg_user_placeholder,0x7000000000,14
/* __LINKEDIT always follows the highest segment; without this one it landed right after
 * __TLGUSER, on the guest image (0xe000000000). Linked at 0xfe00000000, above the guest ranges. */
.zerofill __TLGEND,__end,_tlg_end_placeholder,0x4000,14
