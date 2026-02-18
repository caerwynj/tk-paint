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
	tk->cmd(t, "frame .m -relief raised -bd 2");
	tk->cmd(t, "pack .m -side top -fill x");

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

	# File controls
	tk->cmd(t, "label .m.v -text {v3} -fg #888888 " + FONT);
	tk->cmd(t, "pack .m.v -side right -padx 5");
	tk->cmd(t, "entry .m.e -width 50 " + FONT);
	tk->cmd(t, "pack .m.e -side left");
	tk->cmd(t, ".m.e insert 0 {out.bit}");
	tk->cmd(t, "button .m.save -text Save -command {send cmd save} " + FONT);
	tk->cmd(t, "pack .m.save -side left");
	tk->cmd(t, "button .m.open -text Open -command {send cmd open} " + FONT);
	tk->cmd(t, "pack .m.open -side left");
	tk->cmd(t, "button .m.clear -text Clear -command {send cmd clear} " + FONT);
	tk->cmd(t, "pack .m.clear -side left");

	# Color palette
	tk->cmd(t, "frame .p -relief raised -bd 2");
	tk->cmd(t, "pack .p -side top -fill x");
	colors := array[] of {"black", "white", "red", "green", "blue", "yellow"};
	for(i := 0; i < len colors; i++) {
		c := colors[i];
		tk->cmd(t, "button .p." + c + " -bg " + c + " -width 18 -height 18 -command {send cmd color " + c + "} " + FONT);
		tk->cmd(t, "pack .p." + c + " -side left");
	}

	# Drawing Canvas
	tk->cmd(t, "canvas .c -width " + string CANVAS_WIDTH + " -height " + string CANVAS_HEIGHT + " -bg white");
	tk->cmd(t, "pack .c -side bottom -fill both -expand 1");

	# Bindings
	tk->cmd(t, "bind .c <Button-1> {send cmd b1down %x %y}");
	tk->cmd(t, "bind .c <B1-Motion> {send cmd b1move %x %y}");

	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "ptr"::nil);

	# Backing image for saving
	display := ctxt.display;
	backing := display.newimage(Rect((0, 0), (CANVAS_WIDTH, CANVAS_HEIGHT)), display.image.chans, 0, Draw->White);
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
				tk->cmd(t, ".m.e delete 0 end");
				tk->cmd(t, ".m.e insert 0 {out.bit}");
				tk->cmd(t, ".c delete all");
				backing.draw(backing.r, display.white, nil, (0, 0));
				zoom = 1.0;
			"save" =>
				fname := tk->cmd(t, ".m.e get");
				if(fname != nil) {
					fd := sys->create(fname, Sys->OWRITE, 8r666);
					if(fd != nil)
						display.writeimage(fd, backing);
				}
			"open" =>
				fname := selectfile->filename(ctxt, t.image, "Open .bit image", "*.bit"::nil, "");
				if(fname != "") {
					tk->cmd(t, ".m.e delete 0 end");
					tk->cmd(t, ".m.e insert 0 {" + fname + "}");
					fd := sys->open(fname, Sys->OREAD);
					if(fd != nil) {
						nim := display.readimage(fd);
						if(nim != nil) {
							backing = nim;
							# Try to show it in Tk 
							tk->cmd(t, ".c delete all");
							tk->cmd(t, "image delete " + imgname);
							err := tk->cmd(t, "image create bitmap " + imgname);
							if(err == nil || len err == 0 || err[0] != '!') {
								err = tk->putimage(t, imgname, backing, nil);
								if(err == nil || len err == 0 || err[0] != '!')
									tk->cmd(t, ".c create image 0 0 -anchor nw -image " + imgname);
							}
							zoom = 1.0;
						}
					}
				}
			"clear" =>
				tk->cmd(t, ".c delete all");
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
					tk->cmd(t, ".c scale all 0 0 " + string f + " " + string f);
					zoom = newz;
				}
			"zoomout" =>
				newz := zoom / 1.25;
				if(newz < 0.25)
					newz = 0.25;
				if(newz != zoom) {
					f := newz/zoom;
					tk->cmd(t, ".c scale all 0 0 " + string f + " " + string f);
					zoom = newz;
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
					tk->cmd(t, ".c create line " + string lastx + " " + string lasty + " " + string lastx + " " + string lasty + " -fill " + tkcolor);
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
					tk->cmd(t, ".c create line " + string lastx + " " + string lasty + " " + string x + " " + string y + " -fill " + tkcolor);
				}
			}
		}
	}
}
