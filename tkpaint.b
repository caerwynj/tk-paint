implement Tkpaint;

include "sys.m";
sys: Sys;
include "draw.m";
draw: Draw;
Display, Image, Rect, Point: import draw;
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

CANVAS_WIDTH: con 400;
CANVAS_HEIGHT: con 300;

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
	(t, menubut) := tkclient->toplevel(ctxt, "", "Tk Paint", 0);

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
	tk->cmd(t, "canvas .cf.c -width " + string CANVAS_WIDTH + " -height " + string CANVAS_HEIGHT + " -bg white -xscrollcommand {.cf.x set} -yscrollcommand {.cf.y set}");
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
	backing := display.newimage(Rect((0, 0), (CANVAS_WIDTH, CANVAS_HEIGHT)), display.image.chans, 0, Draw->White);
	if(backing == nil) {
		sys->fprint(sys->fildes(2), "tkpaint: failed to allocate backing image\n");
		raise "fail:nomem";
	}
	tk->cmd(t, ".cf.c configure -scrollregion {0 0 " + string CANVAS_WIDTH + " " + string CANVAS_HEIGHT + "}");

	# State
	lastx, lasty: int;
	drawcolor := display.black;
	tkcolor := "black";
	imgname := "paintimg";
	zoom := 1.0;
	scrollw, scrollh: int;
	zoomtxt := "Zoom: 100%";

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
				tk->cmd(t, ".cf.c delete all");
				backing.draw(backing.r, display.white, nil, (0, 0));
				zoom = 1.0;
				zoomtxt = "Zoom: 100%";
				tk->cmd(t, ".zb.zl configure -text {" + zoomtxt + "}");
				scrollw = backing.r.max.x;
				scrollh = backing.r.max.y;
				tk->cmd(t, ".cf.c configure -scrollregion {0 0 " + string scrollw + " " + string scrollh + "}");
			"save" =>
				fname := selectfile->filename(ctxt, t.image, "Save .bit image", "*.bit"::nil, "");
				if(fname != "") {
					fd := sys->create(fname, Sys->OWRITE, 8r666);
					if(fd != nil)
						display.writeimage(fd, backing);
				}
			"open" =>
				fname := selectfile->filename(ctxt, t.image, "Open .bit image", "*.bit"::nil, "");
				if(fname != "") {
					fd := sys->open(fname, Sys->OREAD);
					if(fd != nil) {
						nim := display.readimage(fd);
						if(nim != nil) {
							backing = nim;
							# Try to show it in Tk 
							tk->cmd(t, ".cf.c delete all");
							tk->cmd(t, "image delete " + imgname);
							err := tk->cmd(t, "image create bitmap " + imgname);
							if(err == nil || len err == 0 || err[0] != '!') {
								err = tk->putimage(t, imgname, backing, nil);
								if(err == nil || len err == 0 || err[0] != '!')
									tk->cmd(t, ".cf.c create image 0 0 -anchor nw -image " + imgname);
							}
							zoom = 1.0;
							zoomtxt = "Zoom: 100%";
							tk->cmd(t, ".zb.zl configure -text {" + zoomtxt + "}");
							scrollw = backing.r.max.x;
							scrollh = backing.r.max.y;
							tk->cmd(t, ".cf.c configure -scrollregion {0 0 " + string scrollw + " " + string scrollh + "}");
						}
					}
				}
			"clear" =>
				tk->cmd(t, ".cf.c delete all");
				backing.draw(backing.r, display.white, nil, (0, 0));
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
				if(newz > 4.0)
					newz = 4.0;
				if(newz != zoom) {
					f := newz/zoom;
					tk->cmd(t, ".cf.c scale all 0 0 " + string f + " " + string f);
					zoom = newz;
					zoomtxt = "Zoom: " + string int (zoom * 100.0) + "%";
					tk->cmd(t, ".zb.zl configure -text {" + zoomtxt + "}");
					scrollw = int (real backing.r.max.x * zoom);
					scrollh = int (real backing.r.max.y * zoom);
					tk->cmd(t, ".cf.c configure -scrollregion {0 0 " + string scrollw + " " + string scrollh + "}");
				}
			"zoomout" =>
				newz := zoom / 1.25;
				if(newz < 0.25)
					newz = 0.25;
				if(newz != zoom) {
					f := newz/zoom;
					tk->cmd(t, ".cf.c scale all 0 0 " + string f + " " + string f);
					zoom = newz;
					zoomtxt = "Zoom: " + string int (zoom * 100.0) + "%";
					tk->cmd(t, ".zb.zl configure -text {" + zoomtxt + "}");
					scrollw = int (real backing.r.max.x * zoom);
					scrollh = int (real backing.r.max.y * zoom);
					tk->cmd(t, ".cf.c configure -scrollregion {0 0 " + string scrollw + " " + string scrollh + "}");
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
					backing.draw(Rect((rx, ry), (rx + 5, ry + 5)), drawcolor, nil, (0, 0));
					tk->cmd(t, ".cf.c create line " + string lastx + " " + string lasty + " " + string lastx + " " + string lasty + " -fill " + tkcolor);
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
					tk->cmd(t, ".cf.c create line " + string lastx + " " + string lasty + " " + string x + " " + string y + " -fill " + tkcolor);
				}
			}
		}
	}
}
