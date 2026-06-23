in_width: f32,
in_height: f32,

out_width: f32,
out_height: f32,

const CoordinateConverter = @This();

pub fn pixelHeight(self: CoordinateConverter) f32 {
    return self.in_height / self.out_height;
}

pub fn outputToInputY(self: CoordinateConverter, out_y: f32) f32 {
    return out_y * self.in_height / self.out_height;
}

pub fn outputToInputX(self: CoordinateConverter, out_x: f32) f32 {
    return out_x * self.in_width / self.out_width;
}

pub fn inputToOutputX(self: CoordinateConverter, in_x: f32) f32 {
    return in_x * self.out_width / self.in_width;
}
