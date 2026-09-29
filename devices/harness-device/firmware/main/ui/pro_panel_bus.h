// The Pro's panel and its backlight, with no renderer attached.
//
// WHY THIS IS ITS OWN FILE. There are two renderers on this board now, and they do not agree about
// anything above the bus: the LVGL one (panel_pro.c + display.c) hands LVGL a draw buffer and flushes
// bands into the framebuffer, while the habitat one (ui/habitat/display_habitat.c) owns the panel
// handle itself, rasterises its own damage strips and pushes them with esp_lcd_panel_draw_bitmap.
//
// What they DO agree about is everything below: the DSI PHY's LDO, the two-lane bus, the DBI io, the
// ST7703's own init, and an inverted LEDC duty on a boost converter. That is what lives here. It was
// inside panel_pro.c until habitat needed it too, and the alternative — a second copy of the bring-up
// sequence in the habitat display — is the kind of duplication that rots the moment one of the two
// timings is corrected and the other is not.
//
// Nothing in here mentions LVGL, so it links into a habitat image that has no LVGL display at all.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_lcd_mipi_dsi.h"
#include "esp_lcd_types.h"

// LDO -> DSI bus -> DBI io -> ST7703 -> reset -> init. Safe before lv_init(); safe with no LVGL at all.
// The panel comes back ready for esp_lcd_panel_draw_bitmap. `out_bus` may be NULL when the caller has
// no use for the bus handle; the DPI callbacks are registered by the caller, because what they signal
// is the caller's business (an LVGL flush_ready, or a habitat DMA fence).
esp_err_t pro_panel_bus_open(esp_lcd_panel_handle_t *out_panel, esp_lcd_dsi_bus_handle_t *out_bus);

// The boost's enable pin and the LEDC timer/channel. Call before the panel, so the rail is up and
// steady while duty is still 0 — there is nothing to show yet and a bright flash of an uninitialised
// framebuffer is the one thing a first boot should not do.
void pro_backlight_init(void);

// 0 = dimmest, 255 = brightest, matching the dial's DCS register range so one UI setting drives both.
void pro_backlight_set(uint8_t level);

// The hard enable, for the idle blank. This panel is backlit, so "off" is the light rather than the
// pixels: cutting the DSI stream instead would need a full re-init to come back from.
void pro_backlight_enable(bool on);

// What the backlight is ACTUALLY being driven with, logged — so a brightness bug and a video bug can be
// told apart from the log instead of by eye. This is why the enable pin is read back rather than
// remembered: the two failures look identical on the glass.
void pro_backlight_log(void);

// What pro_backlight_set() was last given. The idle blank restores through this rather than reading the
// duty back out and converting, which lost a step to integer division every time it blanked.
uint8_t pro_backlight_level(void);
