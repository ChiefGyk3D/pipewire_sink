/*
 * Interposer for pipewire.service. libspa-alsa calls
 * snd_config_update_free_global() in every ALSA PCM node init, freeing the
 * process-wide ALSA config tree while earlier nodes' open handles may still
 * point into it. Core dumps showed heap corruption (free(): invalid
 * pointer/size) in snd_config_delete called from that init. No-op it.
 */
int snd_config_update_free_global(void)
{
	return 0;
}
