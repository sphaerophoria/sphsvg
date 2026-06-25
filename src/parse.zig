const std = @import("std");
const sphtud = @import("sphtud");

pub fn number(buf: *sphtud.lex.Buf) ?sphtud.lex.Range {
    wsp(buf);
    var tmp = buf.tmp();

    _ = sign(&tmp);
    _ = digits(&tmp);
    const has_decimal = tmp.takeOne(".") != null;
    if (has_decimal) {
        _ = digits(&tmp);
    }
    const has_exponent = tmp.takeOne("eE") != null;
    if (has_exponent) {
        _ = sign(&tmp);
        _ = digits(&tmp);
    }

    return buf.commit(tmp);
}

pub fn digits(buf: *sphtud.lex.Buf) ?sphtud.lex.Range {
    comptime std.debug.assert('9' - '0' == 9);
    return buf.takeWhileBetween('0', '9');
}

pub fn hexdigits(buf: *sphtud.lex.Buf) ?sphtud.lex.Range {
    comptime std.debug.assert('9' - '0' == 9);

    var tmp = buf.tmp();
    while (true) {
        if (tmp.takeOneBetween('0', '9') != null) continue;
        if (tmp.takeOneBetween('a', 'f') != null) continue;
        if (tmp.takeOneBetween('A', 'F') != null) continue;
        break;
    }

    return buf.commit(tmp);
}

pub fn sign(buf: *sphtud.lex.Buf) ?sphtud.lex.Idx {
    return buf.takeOne("+-");
}


// https://www.w3.org/TR/SVG2/single-page.html#paths-PathDataBNF
const ws_chars: []const u8 = &.{ 0x9, 0x20, 0xA, 0xC, 0xD };
pub fn wsp(buf: *sphtud.lex.Buf) void {
    _ = buf.takeWhileAny(ws_chars);
}


test number {
    const tests: []const struct { []const u8, []const u8 } = &.{
        .{ ".1234", ".1234" },
        .{ ".1234.123490812309581", ".1234" },
        .{ "0.1234.123490812309581", ".1234" },
        .{ "1..123490812309581", "1." },
        .{ "1..", "1." },
        .{ "1.2.", "1.2" },
        .{ "+1.2.", "+1.2" },
        .{ "-1.2.", "-1.2" },
        .{ "-1.2e10", "-1.2e10" },
        .{ "-1.2e-10", "-1.2e-10" },
    };

    for (tests) |t| {
        var buf = sphtud.lex.Buf.init(t[0]);

        const r = number(&buf) orelse return error.Invalid;
        try std.testing.expectEqualStrings(t[1], r.data(buf));
    }
}

//https://www.w3.org/TR/css-color-3/#svg-color
const ColorName = enum {
    aliceblue,
    antiquewhite,
    aqua,
    aquamarine,
    azure,
    beige,
    bisque,
    black,
    blanchedalmond,
    blue,
    blueviolet,
    brown,
    burlywood,
    cadetblue,
    chartreuse,
    chocolate,
    coral,
    cornflowerblue,
    cornsilk,
    crimson,
    cyan,
    darkblue,
    darkcyan,
    darkgoldenrod,
    darkgray,
    darkgreen,
    darkgrey,
    darkkhaki,
    darkmagenta,
    darkolivegreen,
    darkorange,
    darkorchid,
    darkred,
    darksalmon,
    darkseagreen,
    darkslateblue,
    darkslategray,
    darkslategrey,
    darkturquoise,
    darkviolet,
    deeppink,
    deepskyblue,
    dimgray,
    dimgrey,
    dodgerblue,
    firebrick,
    floralwhite,
    forestgreen,
    fuchsia,
    gainsboro,
    ghostwhite,
    gold,
    goldenrod,
    gray,
    green,
    greenyellow,
    grey,
    honeydew,
    hotpink,
    indianred,
    indigo,
    ivory,
    khaki,
    lavender,
    lavenderblush,
    lawngreen,
    lemonchiffon,
    lightblue,
    lightcoral,
    lightcyan,
    lightgoldenrodyellow,
    lightgray,
    lightgreen,
    lightgrey,
    lightpink,
    lightsalmon,
    lightseagreen,
    lightskyblue,
    lightslategray,
    lightslategrey,
    lightsteelblue,
    lightyellow,
    lime,
    limegreen,
    linen,
    magenta,
    maroon,
    mediumaquamarine,
    mediumblue,
    mediumorchid,
    mediumpurple,
    mediumseagreen,
    mediumslateblue,
    mediumspringgreen,
    mediumturquoise,
    mediumvioletred,
    midnightblue,
    mintcream,
    mistyrose,
    moccasin,
    navajowhite,
    navy,
    oldlace,
    olive,
    olivedrab,
    orange,
    orangered,
    orchid,
    palegoldenrod,
    palegreen,
    paleturquoise,
    palevioletred,
    papayawhip,
    peachpuff,
    peru,
    pink,
    plum,
    powderblue,
    purple,
    red,
    rosybrown,
    royalblue,
    saddlebrown,
    salmon,
    sandybrown,
    seagreen,
    seashell,
    sienna,
    silver,
    skyblue,
    slateblue,
    slategray,
    slategrey,
    snow,
    springgreen,
    steelblue,
    tan,
    teal,
    thistle,
    tomato,
    turquoise,
    violet,
    wheat,
    white,
    whitesmoke,
    yellow,
    yellowgreen,

    fn toRgba(self: ColorName) [4]u8 {
        switch (self) {
            .aliceblue => return .{ 240,248,255, 255},
            .antiquewhite => return .{ 250,235,215, 255 },
            .aqua => return .{ 0,255,255, 255 },
            .aquamarine => return .{ 127,255,212, 255 },
            .azure => return .{ 240,255,255, 255 },
            .beige => return .{ 245,245,220, 255 },
            .bisque => return .{ 255,228,196, 255 },
            .black => return .{ 0,0,0, 255 },
            .blanchedalmond => return .{ 255,235,205, 255 },
            .blue => return .{ 0,0,255, 255 },
            .blueviolet => return .{ 138,43,226, 255 },
            .brown => return .{ 165,42,42, 255 },
            .burlywood => return .{ 222,184,135, 255 },
            .cadetblue => return .{ 95,158,160, 255 },
            .chartreuse => return .{ 127,255,0, 255 },
            .chocolate => return .{ 210,105,30, 255 },
            .coral => return .{ 255,127,80, 255 },
            .cornflowerblue => return .{ 100,149,237, 255 },
            .cornsilk => return .{ 255,248,220, 255 },
            .crimson => return .{ 220,20,60, 255 },
            .cyan => return .{ 0,255,255, 255 },
            .darkblue => return .{ 0,0,139, 255 },
            .darkcyan => return .{ 0,139,139, 255 },
            .darkgoldenrod => return .{ 184,134,11, 255 },
            .darkgray => return .{ 169,169,169, 255 },
            .darkgreen => return .{ 0,100,0, 255 },
            .darkgrey => return .{ 169,169,169, 255 },
            .darkkhaki => return .{ 189,183,107, 255 },
            .darkmagenta => return .{ 139,0,139, 255 },
            .darkolivegreen => return .{ 85,107,47, 255 },
            .darkorange => return .{ 255,140,0, 255 },
            .darkorchid => return .{ 153,50,204, 255 },
            .darkred => return .{ 139,0,0, 255 },
            .darksalmon => return .{ 233,150,122, 255 },
            .darkseagreen => return .{ 143,188,143, 255 },
            .darkslateblue => return .{ 72,61,139, 255 },
            .darkslategray => return .{ 47,79,79, 255 },
            .darkslategrey => return .{ 47,79,79, 255 },
            .darkturquoise => return .{ 0,206,209, 255 },
            .darkviolet => return .{ 148,0,211, 255 },
            .deeppink => return .{ 255,20,147, 255 },
            .deepskyblue => return .{ 0,191,255, 255 },
            .dimgray => return .{ 105,105,105, 255 },
            .dimgrey => return .{ 105,105,105, 255 },
            .dodgerblue => return .{ 30,144,255, 255 },
            .firebrick => return .{ 178,34,34, 255 },
            .floralwhite => return .{ 255,250,240, 255 },
            .forestgreen => return .{ 34,139,34, 255 },
            .fuchsia => return .{ 255,0,255, 255 },
            .gainsboro => return .{ 220,220,220, 255 },
            .ghostwhite => return .{ 248,248,255, 255 },
            .gold => return .{ 255,215,0, 255 },
            .goldenrod => return .{ 218,165,32, 255 },
            .gray => return .{ 128,128,128, 255 },
            .green => return .{ 0,128,0, 255 },
            .greenyellow => return .{ 173,255,47, 255 },
            .grey => return .{ 128,128,128, 255 },
            .honeydew => return .{ 240,255,240, 255 },
            .hotpink => return .{ 255,105,180, 255 },
            .indianred => return .{ 205,92,92, 255 },
            .indigo => return .{ 75,0,130, 255 },
            .ivory => return .{ 255,255,240, 255 },
            .khaki => return .{ 240,230,140, 255 },
            .lavender => return .{ 230,230,250, 255 },
            .lavenderblush => return .{ 255,240,245, 255 },
            .lawngreen => return .{ 124,252,0, 255 },
            .lemonchiffon => return .{ 255,250,205, 255 },
            .lightblue => return .{ 173,216,230, 255 },
            .lightcoral => return .{ 240,128,128, 255 },
            .lightcyan => return .{ 224,255,255, 255 },
            .lightgoldenrodyellow => return .{ 250,250,210, 255 },
            .lightgray => return .{ 211,211,211, 255 },
            .lightgreen => return .{ 144,238,144, 255 },
            .lightgrey => return .{ 211,211,211, 255 },
            .lightpink => return .{ 255,182,193, 255 },
            .lightsalmon => return .{ 255,160,122, 255 },
            .lightseagreen => return .{ 32,178,170, 255 },
            .lightskyblue => return .{ 135,206,250, 255 },
            .lightslategray => return .{ 119,136,153, 255 },
            .lightslategrey => return .{ 119,136,153, 255 },
            .lightsteelblue => return .{ 176,196,222, 255 },
            .lightyellow => return .{ 255,255,224, 255 },
            .lime => return .{ 0,255,0, 255 },
            .limegreen => return .{ 50,205,50, 255 },
            .linen => return .{ 250,240,230, 255 },
            .magenta => return .{ 255,0,255, 255 },
            .maroon => return .{ 128,0,0, 255 },
            .mediumaquamarine => return .{ 102,205,170, 255 },
            .mediumblue => return .{ 0,0,205, 255 },
            .mediumorchid => return .{ 186,85,211, 255 },
            .mediumpurple => return .{ 147,112,219, 255 },
            .mediumseagreen => return .{ 60,179,113, 255 },
            .mediumslateblue => return .{ 123,104,238, 255 },
            .mediumspringgreen => return .{ 0,250,154, 255 },
            .mediumturquoise => return .{ 72,209,204, 255 },
            .mediumvioletred => return .{ 199,21,133, 255 },
            .midnightblue => return .{ 25,25,112, 255 },
            .mintcream => return .{ 245,255,250, 255 },
            .mistyrose => return .{ 255,228,225, 255 },
            .moccasin => return .{ 255,228,181, 255 },
            .navajowhite => return .{ 255,222,173, 255 },
            .navy => return .{ 0,0,128, 255 },
            .oldlace => return .{ 253,245,230, 255 },
            .olive => return .{ 128,128,0, 255 },
            .olivedrab => return .{ 107,142,35, 255 },
            .orange => return .{ 255,165,0, 255 },
            .orangered => return .{ 255,69,0, 255 },
            .orchid => return .{ 218,112,214, 255 },
            .palegoldenrod => return .{ 238,232,170, 255 },
            .palegreen => return .{ 152,251,152, 255 },
            .paleturquoise => return .{ 175,238,238, 255 },
            .palevioletred => return .{ 219,112,147, 255 },
            .papayawhip => return .{ 255,239,213, 255 },
            .peachpuff => return .{ 255,218,185, 255 },
            .peru => return .{ 205,133,63, 255 },
            .pink => return .{ 255,192,203, 255 },
            .plum => return .{ 221,160,221, 255 },
            .powderblue => return .{ 176,224,230, 255 },
            .purple => return .{ 128,0,128, 255 },
            .red => return .{ 255,0,0, 255 },
            .rosybrown => return .{ 188,143,143, 255 },
            .royalblue => return .{ 65,105,225, 255 },
            .saddlebrown => return .{ 139,69,19, 255 },
            .salmon => return .{ 250,128,114, 255 },
            .sandybrown => return .{ 244,164,96, 255 },
            .seagreen => return .{ 46,139,87, 255 },
            .seashell => return .{ 255,245,238, 255 },
            .sienna => return .{ 160,82,45, 255 },
            .silver => return .{ 192,192,192, 255 },
            .skyblue => return .{ 135,206,235, 255 },
            .slateblue => return .{ 106,90,205, 255 },
            .slategray => return .{ 112,128,144, 255 },
            .slategrey => return .{ 112,128,144, 255 },
            .snow => return .{ 255,250,250, 255 },
            .springgreen => return .{ 0,255,127, 255 },
            .steelblue => return .{ 70,130,180, 255 },
            .tan => return .{ 210,180,140, 255 },
            .teal => return .{ 0,128,128, 255 },
            .thistle => return .{ 216,191,216, 255 },
            .tomato => return .{ 255,99,71, 255 },
            .turquoise => return .{ 64,224,208, 255 },
            .violet => return .{ 238,130,238, 255 },
            .wheat => return .{ 245,222,179, 255 },
            .white => return .{ 255,255,255, 255 },
            .whitesmoke => return .{ 245,245,245, 255 },
            .yellow => return .{ 255,255,0, 255 },
            .yellowgreen => return .{ 154,205,50, 255 },
        }
    }
};

const Color = union(enum) {
    name: ColorName,
    rgb: []const u8,
};

fn colorName(buf: *sphtud.lex.Buf) ?ColorName {
    var tmp = buf.tmp();

    wsp(&tmp);
    const color_range = tmp.takeUntilAny(ws_chars) orelse return null;
    const ret = std.meta.stringToEnum(ColorName, color_range.data(tmp)) orelse return null;

    _ = buf.commit(tmp);
    return ret;
}

pub fn color(buf: *sphtud.lex.Buf) ![4]u8 {
    if (colorName(buf)) |n| {
        return n.toRgba();
    }

    if (buf.takeOne("#")) |_| {
        const color_range = hexdigits(buf) orelse return error.Invalid;
        const color_data = color_range.data(buf.*);
        if (color_data.len == 6) {
            return .{
                try std.fmt.parseInt(u8, color_data[0..2], 16),
                try std.fmt.parseInt(u8, color_data[2..4], 16),
                try std.fmt.parseInt(u8, color_data[4..6], 16),
                255,
            };
        } else if (color_data.len == 8) {
            return .{
                try std.fmt.parseInt(u8, color_data[0..2], 16),
                try std.fmt.parseInt(u8, color_data[2..4], 16),
                try std.fmt.parseInt(u8, color_data[4..6], 16),
                try std.fmt.parseInt(u8, color_data[6..8], 16),
            };
        } else {
            return error.Invalid;
        }
    }

    // Lots more to implement. rgb(), rgba(), hsl(), hsla()

    return error.Unimplemented;
}
