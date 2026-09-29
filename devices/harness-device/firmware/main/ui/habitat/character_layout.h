#pragma once
#include "character_types.h"
typedef enum {
    HT_CHARACTER_FULL, HT_CHARACTER_COMPACT, HT_CHARACTER_BRIEF,
    HT_CHARACTER_READING, HT_CHARACTER_QUICK
} ht_character_size_t;
#if HT_FACE_PX >= 720
/*
 * The square face. A font_8 portrait is 27 x 8 = 216 tall, so 126 -> 342 and the recap starts at 366;
 * six rows of ht_mono_28 is 228 px, ending at 594, just clear of the status band at 600. A brief
 * result uses font_10 (270 tall), so 126 -> 396 and three rows from 420 end at 534.
 *
 * 656 / 17 = 38 cells a row. The dial's cap exists because four tapering rows inside a circle
 * genuinely cannot hold more; neither reason applies here, and a recap that fits is the single
 * biggest thing this face changes about living with the device.
 */
enum { HT_CHARACTER_BRIEF_Y = 126, HT_CHARACTER_READING_Y = 126,
       HT_CHARACTER_BRIEF_TEXT_Y = 420, HT_CHARACTER_READING_TEXT_Y = 366,
       HT_CHARACTER_RECAP_CHARS = 228, HT_CHARACTER_RECAP_ROWS = 6,
       // Below the status band (600..638) and in the row the hint would use, which this face leaves
       // empty: the bell IS the chrome here.
       HT_NOTIFICATION_Y = 660 };
#else
enum { HT_CHARACTER_BRIEF_Y = 84, HT_CHARACTER_READING_Y = 82,
       HT_CHARACTER_BRIEF_TEXT_Y = 264, HT_CHARACTER_READING_TEXT_Y = 208,
       HT_CHARACTER_RECAP_CHARS = 90, HT_CHARACTER_RECAP_ROWS = 4,
       HT_NOTIFICATION_Y = 414 };
#endif
typedef struct {
    char pane[128];
    uint32_t began, next_ms;
    uint8_t opacity;
    bool initialized, working, activity;
} ht_character_caption_t;
bool ht_character_caption_tick(ht_character_caption_t *caption, uint32_t now,
                                const char *pane, bool working);
uint16_t ht_character_caption_ink(uint16_t foreground, uint16_t background, uint8_t opacity);
typedef void (*ht_character_painter_t)(ht_scene_t *, const ht_character_face_t *, uint8_t frame,
                                      uint16_t ink, ht_character_size_t size, int y);
void ht_character_layout(ht_scene_t *s, const ht_character_face_t *f, uint8_t frame,
                         uint16_t ink, const char *recap, ht_character_painter_t paint);
// Text-only inbox, deliberately distinct from the companion's home recap.
void ht_inbox_card(ht_scene_t *scene, const char *mark, const char *name,
                   const char *message, uint16_t foreground, uint16_t status_ink);
void ht_notification_bell(ht_scene_t *scene, unsigned count, uint16_t ink);
// The envelope is painted in the character's own cells, attached to its limb.
void ht_character_letter(ht_scene_t *s, const ht_character_face_t *f,
                         const ht_font_t *font, int x, int y);
