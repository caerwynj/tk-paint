implement Tkpaint;

include "sys.m";
sys: Sys;
include "draw.m";
draw: Draw;
Display, Image, Rect, Point, Chans: import draw;
include "tk.m";
tk: Tk;
include "tkclient.m";
tkclient: Tkclient;
include "string.m";
str: String;
include "selectfile.m";
selectfile: Selectfile;

Tkpaint: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

CANVAS_WIDTH: con 16;
CANVAS_HEIGHT: con 16;

render: fn(t: ref Tk->Toplevel, tk: Tk, display: ref Display, backing: ref Image, zoom: real,
	imgname: string, imgmade: int, bpp: int): (ref Image, int, int, int, int, int);
resample: fn(src: array of byte, dst: array of byte, w_src, w_dst, depth: int, zoom: real);
writeimage_uncompressed: fn(fd: ref Sys->FD, i: ref Image): int;
get_new_dims: fn(ctxt: ref Draw->Context): (int, int);


render(t: ref Tk->Toplevel, tk: Tk, display: ref Display, backing: ref Image, zoom: real,
	imgname: string, imgmade: int, bpp: int): (ref Image, int, int, int, int, int)
{
	if(backing == nil)
		return (nil, 0, 0, imgmade, 0, 0);

	vieww := int (real backing.r.max.x * zoom);
	viewh := int (real backing.r.max.y * zoom);
	if(vieww < 1)
		vieww = 1;
	if(viewh < 1)
		viewh = 1;

	view: ref Image;
	if(zoom == 1.0) {
		view = backing;
	} else {
		view = display.newimage(Rect((0, 0), (vieww, viewh)), backing.chans, 0, Draw->White);
		if(view == nil)
			return (nil, vieww, viewh, imgmade, vieww, viewh);
		
		# Optimization: Process row by row instead of pixel by pixel
		depth := backing.depth;
		src_stride := (backing.r.max.x * depth + 7) / 8;
		dst_stride := (vieww * depth + 7) / 8;
		
		src_row := array[src_stride] of byte;
		dst_row := array[dst_stride] of byte;
		
		last_sy := -1;
		
		for(y := 0; y < viewh; y++) {
			sy := int (real y / zoom);
			if(sy >= backing.r.max.y) break;

			if(sy != last_sy) {
				backing.readpixels(Rect((0, sy), (backing.r.max.x, sy + 1)), src_row);
				resample(src_row, dst_row, backing.r.max.x, vieww, depth, zoom);
				last_sy = sy;
			}
			view.writepixels(Rect((0, y), (vieww, y + 1)), dst_row);
		}

		# Draw gridlines if zoomed in
		if(zoom >= 4.0) {
			gridcolor := display.rgb(128, 128, 128);
			# Vertical lines
			for(x := 1; x < vieww; x++) {
				if(int(real x / zoom) != int(real (x-1) / zoom)) {
					view.line((x, 0), (x, viewh), 0, 0, 0, gridcolor, (0, 0));
				}
			}
			# Horizontal lines
			for(y := 1; y < viewh; y++) {
				if(int(real y / zoom) != int(real (y-1) / zoom)) {
					view.line((0, y), (vieww, y), 0, 0, 0, gridcolor, (0, 0));
				}
			}
		}
	}

	if(imgmade == 0) {
		err := tk->cmd(t, "image create bitmap " + imgname);
		if(err == nil || len err == 0 || err[0] != '!') {
			imgmade = 1;
		} else {
			return (view, vieww, viewh, imgmade, vieww, viewh);
		}
	}

	tk->cmd(t, ".cf.c delete all");
	err := tk->putimage(t, imgname, view, nil);
	if(err == nil || len err == 0 || err[0] != '!')
		tk->cmd(t, ".cf.c create image 0 0 -anchor nw -image " + imgname);

	tk->cmd(t, ".cf.c configure -scrollregion {0 0 " + string vieww + " " + string viewh + "}");
	return (view, vieww, viewh, imgmade, vieww, viewh);
}

resample(src: array of byte, dst: array of byte, nil, w_dst: int, depth: int, zoom: real)
{
	# Nearest neighbor resampling
	# Note: This implementation assumes typical depths (1, 2, 4, 8, 16, 24, 32)
	
	if(depth >= 8) {
		bpp := depth / 8;
		for(x := 0; x < w_dst; x++) {
			sx := int(real x / zoom);
			# Bound check is implicitly handled by zoom/width logic but good to be safe if desired
			# Copy pixel
			src_idx := sx * bpp;
			dst_idx := x * bpp;
			if(src_idx + bpp <= len src && dst_idx + bpp <= len dst)
				dst[dst_idx:] = src[src_idx:src_idx+bpp];
		}
	} else {
		# Sub-byte depths (1, 2, 4 bpp)
		# Pixels are packed.
		pixels_per_byte := 8 / depth;
		mask := (1 << depth) - 1;
		
		# Clear dst buffer first as we OR in bits
		for(i := 0; i < len dst; i++) dst[i] = byte 0;

		for(x := 0; x < w_dst; x++) {
			sx := int(real x / zoom);
			
			# Read source pixel
			src_byte_idx := (sx * depth) / 8;
			src_bit_shift := 8 - ((sx * depth) % 8) - depth;
			
			pixel := (int src[src_byte_idx] >> src_bit_shift) & mask;
			
			# Write dest pixel
			dst_byte_idx := (x * depth) / 8;
			dst_bit_shift := 8 - ((x * depth) % 8) - depth;
			
			if(dst_byte_idx < len dst)
				dst[dst_byte_idx] |= byte (pixel << dst_bit_shift);
		}
	}
}

writeimage_uncompressed(fd: ref Sys->FD, i: ref Image): int
{
	# Write uncompressed header: chan minx miny maxx maxy
	header := sys->sprint("%11s %11d %11d %11d %11d ", 
		i.chans.text(), i.r.min.x, i.r.min.y, i.r.max.x, i.r.max.y);
	d := array of byte header;
	if(sys->write(fd, d, len d) != len d)
		return -1;

	# Write pixel data row by row
	depth := i.depth;
	stride := (i.r.dx() * depth + 7) / 8;
	buf := array[stride] of byte;
	
	for(y := i.r.min.y; y < i.r.max.y; y++) {
		i.readpixels(Rect((i.r.min.x, y), (i.r.max.x, y+1)), buf);
		if(sys->write(fd, buf, len buf) != len buf)
			return -1;
	}
	return 0;
}

get_new_dims(ctxt: ref Draw->Context): (int, int)
{
	(t, nil) := tkclient->toplevel(ctxt, "", "Image Size", Tkclient->Appl);
	
	cmd := chan of string;
	tk->namechan(t, cmd, "cmd");

	tk->cmd(t, "frame .f");
	tk->cmd(t, "label .f.lw -text Width:");
	tk->cmd(t, "entry .f.ew -width 55");
	tk->cmd(t, ".f.ew insert 0 " + string CANVAS_WIDTH);
	tk->cmd(t, "label .f.lh -text Height:");
	tk->cmd(t, "entry .f.eh -width 55");
	tk->cmd(t, ".f.eh insert 0 " + string CANVAS_HEIGHT);
	tk->cmd(t, "pack .f.lw .f.ew .f.lh .f.eh -side left -padx 5 -pady 5");
	tk->cmd(t, "pack .f -side top");
	
	tk->cmd(t, "frame .b");
	tk->cmd(t, "button .b.ok -text OK -command {send cmd ok}");
	tk->cmd(t, "button .b.cancel -text Cancel -command {send cmd cancel}");
	tk->cmd(t, "pack .b.ok .b.cancel -side left -padx 5 -pady 5");
	tk->cmd(t, "pack .b -side bottom");
	
	tk->cmd(t, "focus .f.ew");
	tk->cmd(t, "bind .f.ew <Key-Return> {send cmd ok}");
	tk->cmd(t, "bind .f.eh <Key-Return> {send cmd ok}");

	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd"::"ptr"::nil);

	w := 0;
	h := 0;
	
	loop: for(;;) {
		alt {
		c := <-cmd =>
			case c {
			"ok" =>
				w = int tk->cmd(t, ".f.ew get");
				h = int tk->cmd(t, ".f.eh get");
				if(w <= 0) w = CANVAS_WIDTH;
				if(h <= 0) h = CANVAS_HEIGHT;
				break loop;
			"cancel" =>
				w = 0;
				h = 0;
				break loop;
			}
		c := <-t.ctxt.kbd =>
			tk->keyboard(t, c);
		c := <-t.ctxt.ptr =>
			tk->pointer(t, *c);
		s := <-t.ctxt.ctl or
		s = <-t.wreq =>
			tkclient->wmctl(t, s);
		}
	}
	tk->cmd(t, "destroy .");
	return (w, h);
}


init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	str = load String String->PATH;
	selectfile = load Selectfile Selectfile->PATH;

	tkclient->init();
	selectfile->init();
	if(ctxt == nil) {
		ctxt = tkclient->makedrawcontext();
	}
	if(ctxt == nil) {
		sys->fprint(sys->fildes(2), "tkpaint: no window context\n");
		raise "fail:bad context";
	}
	(t, menubut) := tkclient->toplevel(ctxt, "", "Tk Paint", Tkclient->Appl);

	cmdchan := chan of string;
	tk->namechan(t, cmdchan, "cmd");

	# Main layout
	tk->cmd(t, "frame .mb -relief raised -bd 2");
	tk->cmd(t, "pack .mb -side top -fill x");

	FONT := "-font /fonts/lucida/unicode.10.font";
	FONT = "";

	# Menu bar
	tk->cmd(t, "menubutton .mb.file -text File -menu .mb.file.menu");
	tk->cmd(t, "menubutton .mb.view -text View -menu .mb.view.menu");
	tk->cmd(t, "pack .mb.file .mb.view -side left");
	tk->cmd(t, "menu .mb.file.menu");
	tk->cmd(t, ".mb.file.menu add command -label New -command {send cmd new}");
	tk->cmd(t, ".mb.file.menu add command -label Open... -command {send cmd open}");
	tk->cmd(t, ".mb.file.menu add command -label Save -command {send cmd save}");
	tk->cmd(t, "menu .mb.view.menu");
	tk->cmd(t, "menu .mb.view.menu.zoom");
	tk->cmd(t, ".mb.view.menu add cascade -label Zoom -menu .mb.view.menu.zoom");
	tk->cmd(t, ".mb.view.menu.zoom add command -label {Zoom In} -command {send cmd zoomin}");
	tk->cmd(t, ".mb.view.menu.zoom add command -label {Zoom Out} -command {send cmd zoomout}");

	# Zoom controls
	tk->cmd(t, "frame .zb -relief raised -bd 2");
	tk->cmd(t, "pack .zb -side top -fill x");
	tk->cmd(t, "label .zb.zl -text {Zoom: 100%}");
	tk->cmd(t, "button .zb.zi -text {Zoom In} -command {send cmd zoomin}");
	tk->cmd(t, "button .zb.zo -text {Zoom Out} -command {send cmd zoomout}");
	tk->cmd(t, "pack .zb.zl .zb.zi .zb.zo -side left");

	# Color palette
	tk->cmd(t, "frame .p -relief raised -bd 2");
	tk->cmd(t, "pack .p -side top -fill x");
	colors := array[] of {"black", "white", "red", "green", "blue", "yellow"};
	for(i := 0; i < len colors; i++) {
		c := colors[i];
		tk->cmd(t, "button .p." + c + " -bg " + c + " -width 18 -height 18 -command {send cmd color " + c + "} " + FONT);
		tk->cmd(t, "pack .p." + c + " -side left");
	}

	# Drawing Canvas + scrollbars
	tk->cmd(t, "frame .cf");
	tk->cmd(t, "pack .cf -side bottom -fill both -expand 1");
	tk->cmd(t, "scrollbar .cf.x -orient horizontal -command {.cf.c xview}");
	tk->cmd(t, "scrollbar .cf.y -orient vertical -command {.cf.c yview}");
	tk->cmd(t, "canvas .cf.c -width " + string CANVAS_WIDTH + " -height " + string CANVAS_HEIGHT + " -bg gray -xscrollcommand {.cf.x set} -yscrollcommand {.cf.y set}");
	tk->cmd(t, "grid .cf.c .cf.y -sticky nsew");
	tk->cmd(t, "grid .cf.x - -sticky ew");
	tk->cmd(t, "grid columnconfigure .cf 0 -weight 1");
	tk->cmd(t, "grid rowconfigure .cf 0 -weight 1");

	# Bindings
	tk->cmd(t, "bind .cf.c <Button-1> {send cmd b1down %x %y}");
	tk->cmd(t, "bind .cf.c <B1-Motion> {send cmd b1move %x %y}");

	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "ptr"::nil);

	# Backing image for saving
	display := ctxt.display;
	backing := display.newimage(Rect((0, 0), (CANVAS_WIDTH, CANVAS_HEIGHT)), Draw->RGB24, 0, Draw->White);
	if(backing == nil) {
		sys->fprint(sys->fildes(2), "tkpaint: failed to allocate backing image\n");
		raise "fail:nomem";
	}

	# State
	lastx, lasty: int;
	drawcolor := display.black;
	tkcolor := "black";
	imgname := "paintimg";
	zoom := 1.0;
	scrollw, scrollh: int;
	zoomtxt := "Zoom: 100%";
	view: ref Image;
	vieww, viewh: int;
	imgmade := 0;
	bpp := (backing.depth + 7) / 8;
	(view, vieww, viewh, imgmade, scrollw, scrollh) = render(t, tk, display, backing, zoom, imgname, imgmade, bpp);

	# Loop
	stop := chan of int;
	spawn tkclient->handler(t, stop);

	for(;;) {
		alt {
		menu := <- menubut =>
			if(menu == "exit") {
				stop <- = 1;
				return;
			}
			tkclient->wmctl(t, menu);
		val := <- cmdchan =>
			(nil, args) := sys->tokenize(val, " ");
			case hd args {
			"new" =>
				(nw, nh) := get_new_dims(ctxt);
				if(nw > 0 && nh > 0) {
					tk->cmd(t, ".cf.c delete all");
					backing = display.newimage(Rect((0, 0), (nw, nh)), Draw->RGB24, 0, Draw->White);
					zoom = 1.0;
					zoomtxt = "Zoom: 100%";
					tk->cmd(t, ".zb.zl configure -text {" + zoomtxt + "}");
					(view, vieww, viewh, imgmade, scrollw, scrollh) = render(t, tk, display, backing, zoom, imgname, imgmade, bpp);
				}
			"save" =>
				fname := selectfile->filename(ctxt, t.image, "Save .bit image", "*.bit"::nil, "");
				if(fname != "") {
					fd := sys->create(fname, Sys->OWRITE, 8r666);
					if(fd != nil)
						writeimage_uncompressed(fd, backing);
				}
			"open" =>
				fname := selectfile->filename(ctxt, t.image, "Open .bit image", "*.bit"::nil, "");
				if(fname != "") {
					fd := sys->open(fname, Sys->OREAD);
					if(fd != nil) {
						nim := display.readimage(fd);
						if(nim != nil) {
							# Create a fresh backing image to ensure consistent format and coordinates
							backing = display.newimage(Rect((0, 0), (CANVAS_WIDTH, CANVAS_HEIGHT)), Draw->RGB24, 0, Draw->White);
							backing.draw(backing.r, nim, nil, nim.r.min);
							
							zoom = 1.0;
							zoomtxt = "Zoom: 100%";
							tk->cmd(t, ".zb.zl configure -text {" + zoomtxt + "}");
							bpp = (backing.depth + 7) / 8;
							(view, vieww, viewh, imgmade, scrollw, scrollh) = render(t, tk, display, backing, zoom, imgname, imgmade, bpp);
						}
					}
				}
			"clear" =>
				tk->cmd(t, ".cf.c delete all");
				backing.draw(backing.r, display.white, nil, (0, 0));
				(view, vieww, viewh, imgmade, scrollw, scrollh) = render(t, tk, display, backing, zoom, imgname, imgmade, bpp);
			"color" =>
				tkcolor = hd tl args;
				case tkcolor {
				"black" =>
					drawcolor = display.black;
				"white" =>
					drawcolor = display.white;
				"red" =>
					drawcolor = display.color(Draw->Red);
				"green" =>
					drawcolor = display.color(Draw->Green);
				"blue" =>
					drawcolor = display.color(Draw->Blue);
				"yellow" =>
					drawcolor = display.color(Draw->Yellow);
				}
			"zoomin" =>
				newz := zoom * 1.25;
				if(newz > 16.0)
					newz = 16.0;
				if(newz != zoom) {
					zoom = newz;
					zoomtxt = "Zoom: " + string int (zoom * 100.0) + "%";
					tk->cmd(t, ".zb.zl configure -text {" + zoomtxt + "}");
					(view, vieww, viewh, imgmade, scrollw, scrollh) = render(t, tk, display, backing, zoom, imgname, imgmade, bpp);
				}
			"zoomout" =>
				newz := zoom / 1.25;
				if(newz < 0.25)
					newz = 0.25;
				if(newz != zoom) {
					zoom = newz;
					zoomtxt = "Zoom: " + string int (zoom * 100.0) + "%";
					tk->cmd(t, ".zb.zl configure -text {" + zoomtxt + "}");
					(view, vieww, viewh, imgmade, scrollw, scrollh) = render(t, tk, display, backing, zoom, imgname, imgmade, bpp);
				}
			"b1down" =>
				if(len args >= 3) {
					if(backing == nil)
						break;
					lastx = int hd tl args;
					lasty = int hd tl tl args;
					# plot point 
					rx := int (real lastx / zoom);
					ry := int (real lasty / zoom);
					backing.draw(Rect((rx, ry), (rx + 1, ry + 1)), drawcolor, nil, (0, 0));
					if(zoom == 1.0) {
						tk->cmd(t, ".cf.c create line " + string lastx + " " + string lasty + " " + string lastx + " " + string lasty + " -fill " + tkcolor);
					} else {
						(view, vieww, viewh, imgmade, scrollw, scrollh) = render(t, tk, display, backing, zoom, imgname, imgmade, bpp);
					}
				}
			"b1move" =>
				if(len args >= 3) {
					if(backing == nil)
						break;
					x := int hd tl args;
					y := int hd tl tl args;
					rx0 := int (real lastx / zoom);
					ry0 := int (real lasty / zoom);
					rx1 := int (real x / zoom);
					ry1 := int (real y / zoom);
					backing.line((rx0, ry0), (rx1, ry1), 0, 0, 0, drawcolor, (0, 0));
					lastx = x;
					lasty = y;
					if(zoom == 1.0) {
						tk->cmd(t, ".cf.c create line " + string lastx + " " + string lasty + " " + string x + " " + string y + " -fill " + tkcolor);
					} else {
						(view, vieww, viewh, imgmade, scrollw, scrollh) = render(t, tk, display, backing, zoom, imgname, imgmade, bpp);
					}
				}
			}
		}
	}
}

