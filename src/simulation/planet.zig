const std = @import("std");
const gl = @import("gl");
const za = @import("zalgebra");
const tracy = @import("../vendor/tracy.zig");

const perlin = @import("../perlin.zig");
const EventLoop = @import("../loop.zig").EventLoop;

const Lifeform = @import("life.zig").Lifeform;

const Vec3 = za.Vec3;

const icoX = 0.525731112119133606;
const icoZ = 0.850650808352039932;
const icoVertices = &[_]f32 {
	-icoX, 0,  icoZ,
	 icoX, 0,  icoZ,
	-icoX, 0, -icoZ,
	 icoX, 0, -icoZ,
	0,  icoZ,  icoX,
	0,  icoZ, -icoX,
	0, -icoZ,  icoX,
	0, -icoZ, -icoX,
	 icoZ,  icoX, 0,
	-icoZ,  icoX, 0,
	 icoZ, -icoX, 0,
	-icoZ, -icoX, 0,
};

const icoIndices = &[_]gl.GLuint {
	0, 4, 1, 0, 9, 4, 9, 5, 4, 4, 5, 8, 4, 8, 1, 8, 10, 1, 8, 3, 10, 5, 3, 8,
	5, 2, 3, 2, 7, 3, 7, 10, 3, 7, 6, 10, 7, 11, 6, 11, 0, 6, 0, 1, 6,
	6, 1, 10, 9, 0, 11, 9, 11, 2, 9, 2, 5, 7, 2, 11
};

const IndexPair = struct {
	first: gl.GLuint,
	second: gl.GLuint
};

pub const Planet = struct {
	vao: gl.GLuint,
	vbo: gl.GLuint,

	numTriangles: gl.GLint,
	numSubdivisions: usize,
	radius: f32,
	allocator: std.mem.Allocator,
	/// The *unmodified* vertices of the icosphere
	vertices: []Vec3,
	indices: []gl.GLuint,
	/// Slice changed during each upload() call, it contains the data
	/// that will be stored in the VBO.
	bufData: []f32,

	/// The water elevation (TODO: replace with something better?)
	/// Unit: Kilometer
	waterElevation: []f32,
	/// The elevation of each point.
	/// Unit: Kilometer
	elevation: []f32,
	/// Temperature measured
	/// Unit: Kelvin
	temperature: []f32,
	/// Buffer array that is used to store the temperatures to be used after next update
	newTemperature: []f32,
	newWaterElevation: []f32,
	lifeforms: std.ArrayList(Lifeform),

	// 0xFFFFFFFF in the first entry considered null and not filled
	/// List of neighbours for a vertex. A vertex has 6 neighbours that arrange in hexagons
	/// Neighbours are stored as u32 as icospheres with more than 4 billions vertices aren't worth
	/// supporting.
	verticesNeighbours: [][6]u32,

	const LookupMap = std.AutoHashMap(IndexPair, gl.GLuint);
	fn vertexForEdge(lookup: *LookupMap, vertices: *std.ArrayList(f32), first: gl.GLuint, second: gl.GLuint) !gl.GLuint {
		const a = if (first > second) first  else second;
		const b = if (first > second) second else first;

		const pair = IndexPair { .first = a, .second = b };
		const result = try lookup.getOrPut(pair);
		if (!result.found_existing) {
			result.value_ptr.* = @intCast(gl.GLuint, vertices.items.len / 3);
			const edge0 = Vec3.new(
				vertices.items[a*3+0],
				vertices.items[a*3+1],
				vertices.items[a*3+2],
			);
			const edge1 = Vec3.new(
				vertices.items[b*3+0],
				vertices.items[b*3+1],
				vertices.items[b*3+2],
			);
			const point = edge0.add(edge1).norm();
			try vertices.append(point.x());
			try vertices.append(point.y());
			try vertices.append(point.z());
		}

		return result.value_ptr.*;
	}

	const IndexedMesh = struct {
		vertices: []f32,
		indices: []gl.GLuint
	};

	fn subdivide(allocator: std.mem.Allocator, vertices: []const f32, indices: []const gl.GLuint) !IndexedMesh {
		var lookup = LookupMap.init(allocator);
		defer lookup.deinit();
		var result = std.ArrayList(gl.GLuint).init(allocator);
		var verticesList = std.ArrayList(f32).init(allocator);
		try verticesList.appendSlice(vertices);

		var i: usize = 0;
		while (i < indices.len) : (i += 3) {
			var mid: [3]gl.GLuint = undefined;
			var edge: usize = 0;
			while (edge < 3) : (edge += 1) {
				mid[edge] = try vertexForEdge(&lookup, &verticesList,
					indices[i+edge], indices[i+(edge+1)%3]);
			}

			try result.ensureUnusedCapacity(12);
			result.appendAssumeCapacity(indices[i+0]);
			result.appendAssumeCapacity(mid[0]);
			result.appendAssumeCapacity(mid[2]);

			result.appendAssumeCapacity(indices[i+1]);
			result.appendAssumeCapacity(mid[1]);
			result.appendAssumeCapacity(mid[0]);

			result.appendAssumeCapacity(indices[i+2]);
			result.appendAssumeCapacity(mid[2]);
			result.appendAssumeCapacity(mid[1]);

			result.appendAssumeCapacity(mid[0]);
			result.appendAssumeCapacity(mid[1]);
			result.appendAssumeCapacity(mid[2]);
		}

		return IndexedMesh {
			.vertices = verticesList.toOwnedSlice(),
			.indices = result.toOwnedSlice(),
		};
	}

	fn appendNeighbor(planet: *Planet, idx: u32, neighbor: u32) void {
		// Find the next free slot in the list:
		var i: usize = 0;
		while (i < 6) : (i += 1) {
			if(planet.verticesNeighbours[idx][i] == idx) {
				planet.verticesNeighbours[idx][i] = neighbor;
				return;
			} else if(planet.verticesNeighbours[idx][i] == neighbor) {
				return; // The neighbor was already added.
			}
		}
		unreachable;
	}

	fn computeNeighbours(planet: *Planet) void {
		const zone = tracy.ZoneN(@src(), "Compute points neighbours");
		defer zone.End();

		const indices = planet.indices;
		const vertNeighbours = planet.verticesNeighbours;
		var i: u32 = 0;
		// Clear the vertex list:
		while (i < vertNeighbours.len) : (i += 1) {
			var j: u32 = 0;
			while (j < 6) : (j += 1) {
				vertNeighbours[i][j] = i;
			}
		}

		// Loop through all triangles
		i = 0;
		while (i < indices.len) : (i += 3) {
			const aIdx = indices[i+0];
			const bIdx = indices[i+1];
			const cIdx = indices[i+2];
			appendNeighbor(planet, aIdx, bIdx);
			appendNeighbor(planet, aIdx, cIdx);
			appendNeighbor(planet, bIdx, aIdx);
			appendNeighbor(planet, bIdx, cIdx);
			appendNeighbor(planet, cIdx, aIdx);
			appendNeighbor(planet, cIdx, bIdx);
		}
	}

	/// Note: the data is allocated using the event loop's allocator
	pub fn generate(allocator: std.mem.Allocator, numSubdivisions: usize, radius: f32) !Planet {
		const zone = tracy.ZoneN(@src(), "Generate planet");
		defer zone.End();

		const zone2 = tracy.ZoneN(@src(), "Subdivide ico-sphere");
		var vao: gl.GLuint = undefined;
		gl.genVertexArrays(1, &vao);
		var vbo: gl.GLuint = undefined;
		gl.genBuffers(1, &vbo);
		var ebo: gl.GLuint = undefined;
		gl.genBuffers(1, &ebo);

		gl.bindVertexArray(vao);
		gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
		gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
		
		var subdivided: ?IndexedMesh = null;
		{
			var i: usize = 0;
			while (i < numSubdivisions) : (i += 1) {
				const oldSubdivided = subdivided;
				const vert = if (subdivided) |s| s.vertices else icoVertices;
				const indc = if (subdivided) |s| s.indices else icoIndices;
				subdivided = try subdivide(allocator, vert, indc);

				if (oldSubdivided) |s| {
					allocator.free(s.vertices);
					allocator.free(s.indices);
				}
			}
		}
		zone2.End();

		const zone3 = tracy.ZoneN(@src(), "Initialise with data");
		const vertices       = try allocator.alloc(Vec3, subdivided.?.vertices.len / 3);
		const vertNeighbours = try allocator.alloc([6]u32, subdivided.?.vertices.len / 3);
		const elevation      = try allocator.alloc(f32, subdivided.?.vertices.len / 3);
		const waterElev      = try allocator.alloc(f32, subdivided.?.vertices.len / 3);
		const temperature    = try allocator.alloc(f32, subdivided.?.vertices.len / 3);
		const newTemp        = try allocator.alloc(f32, subdivided.?.vertices.len / 3);
		const newWaterElev   = try allocator.alloc(f32, subdivided.?.vertices.len / 3);
		
		var planet = Planet {
			.vao = vao,
			.vbo = vbo,
			.numTriangles = @intCast(gl.GLint, subdivided.?.indices.len),
			.numSubdivisions = numSubdivisions,
			.radius = radius,
			.allocator = allocator,
			.vertices = vertices,
			.verticesNeighbours = vertNeighbours,
			.indices = subdivided.?.indices,
			.elevation = elevation,
			.waterElevation = waterElev,
			.newWaterElevation = newWaterElev,
			.temperature = temperature,
			.newTemperature = newTemp,
			.bufData = try allocator.alloc(f32, vertices.len * 5),
			.lifeforms = std.ArrayList(Lifeform).init(allocator),
		};

		{
			var i: usize = 0;
			const vert = subdivided.?.vertices;
			defer allocator.free(vert);
			while (i < vert.len) : (i += 3) {
				var point = Vec3.fromSlice(vert[i..]);

				const theta = std.math.acos(point.z());
				const phi = std.math.atan2(f32, point.y(), point.x());
				// TODO: 3D perlin (or simplex) noise for correct looping
				const value = radius + perlin.p2do(theta * 3 + 74, phi * 3 + 42, 4) * (radius / 20);

				elevation[i / 3] = value;
				waterElev[i / 3] = std.math.max(0, value - radius);
				temperature[i / 3] = (perlin.p2do(theta * 10 + 1, phi * 10 + 1, 6) + 1) * 300; // 0°C
				vertices[i / 3] = point.norm();
			}
		}
		zone3.End();

		gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(isize, subdivided.?.indices.len * @sizeOf(f32)), subdivided.?.indices.ptr, gl.STATIC_DRAW);
		gl.vertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 5 * @sizeOf(f32), @intToPtr(?*anyopaque, 0 * @sizeOf(f32)));
		gl.vertexAttribPointer(1, 1, gl.FLOAT, gl.FALSE, 5 * @sizeOf(f32), @intToPtr(?*anyopaque, 3 * @sizeOf(f32)));
		gl.vertexAttribPointer(2, 1, gl.FLOAT, gl.FALSE, 5 * @sizeOf(f32), @intToPtr(?*anyopaque, 4 * @sizeOf(f32)));
		gl.enableVertexAttribArray(0);
		gl.enableVertexAttribArray(1);
		gl.enableVertexAttribArray(2);

		// Pre-compute the neighbours of every point of the ico-sphere.
		computeNeighbours(&planet);

		return planet;
	}

	/// Upload all changes to the GPU
	pub fn upload(self: Planet) void {
		const zone = tracy.ZoneN(@src(), "Planet GPU Upload");
		defer zone.End();
		
		// TODO: as it's reused for every upload, just pre-allocate bufData
		const bufData = self.bufData;

		for (self.vertices) |point, i| {
			const transformedPoint = point.scale(self.elevation[i] + self.waterElevation[i]);
			bufData[i*5+0] = transformedPoint.x();
			bufData[i*5+1] = transformedPoint.y();
			bufData[i*5+2] = transformedPoint.z();
			bufData[i*5+3] = self.temperature[i];
			bufData[i*5+4] = self.waterElevation[i];
		}
		
		gl.bindVertexArray(self.vao);
		gl.bindBuffer(gl.ARRAY_BUFFER, self.vbo);
		gl.bufferData(gl.ARRAY_BUFFER, @intCast(isize, bufData.len * @sizeOf(f32)), bufData.ptr, gl.STREAM_DRAW);
	}

	pub const Direction = enum {
		ForwardLeft,
		BackwardLeft,
		Left,
		ForwardRight,
		BackwardRight,
		Right,
	};

	fn contains(list: anytype, element: usize) bool {
		for (list.constSlice()) |item| {
			if (item == element) return true;
		}
		return false;
	}

	pub fn getNeighbour(self: Planet, idx: usize, direction: Direction) usize {
		const directionInt = @enumToInt(direction);
		return self.verticesNeighbours[idx][directionInt];
	}

	pub const SimulationOptions = struct {
		solarConstant: f32,
		conductivity: f32,
		/// Currently, time scale greater than 1 may result in lots of bugs
		timeScale: f32 = 1,
	};

	pub fn simulate(self: *Planet, solarVector: Vec3, options: SimulationOptions) void {
		const zone = tracy.ZoneN(@src(), "Simulate planet");
		defer zone.End();

		const newTemp = self.newTemperature;
		// Fill newTemp with the current temperatures
		for (self.vertices) |_, i| {
			newTemp[i] = std.math.max(0, self.temperature[i]); // temperature may never go below 0°K
		}

		// Number of seconds that passes in 1 simulation step
		const dt = 1.0 / 60.0 * options.timeScale * 100;

		// The surface of the planet (approx.) divided by the numbers of points
		const meanPointArea = (4 * std.math.pi * (self.radius * 1000) * (self.radius * 1000)) / @intToFloat(f32, self.vertices.len);

		// NEW(TM) heat simulation
		for (self.vertices) |vert, i| {
			// Temperature in the current cell
			const temp = self.temperature[i];

			// In W.m-1.K-1, this is 1 assuming 100% of planet is SiO2 :/
			const thermalConductivity = 1;

			// again, assume 100% SiO2 to the *receiving* end (us)
			const specificHeatCapacity = 700; // J/K/kg
			// Earth is about 5513 kg/m³ (https://nssdc.gsfc.nasa.gov/planetary/factsheet/earthfact.html) and assume each point is 1mm thick??
			const pointMass = meanPointArea * 0.001 * 5513; // kg
			const heatCapacity = specificHeatCapacity * pointMass; // J.K-1

			inline for (std.meta.fields(Planet.Direction)) |directionField| {
				const neighbourDirection = @intToEnum(Planet.Direction, directionField.value);
				const neighbourIndex = self.getNeighbour(i, neighbourDirection);

				const neighbourPos = self.vertices[neighbourIndex];
				const dP = neighbourPos.sub(vert); // delta position

				// dx will be the distance to the point
				// * 1000 is to convert from km to m
				const dx = dP.length() * 1000;
				// Assume area is equals to dx²
				const pointArea = dx * dx / 2;

				// We compute the 1-dimensional gradient of T (temperature)
				// aka T1 - T2
				const dT = self.temperature[neighbourIndex] - temp;
				if (dT < 0) {
					// Heat transfer only happens from the hot point to the cold one

					// Rate of heat flow density
					const qx = -thermalConductivity * dT / dx; // W.m-2
					const watt = qx * pointArea; // W = J.s-1
					// So, we get heat transfer in J
					const heatTransfer = watt * dt;

					// it is assumed neighbours are made of the exact same materials
					// as this point
					const temperatureGain = heatTransfer / heatCapacity; // K
					newTemp[neighbourIndex] += temperatureGain;
					newTemp[i] -= temperatureGain;
				}
			}

			// Solar illumination
			{
				const solarCoeff = std.math.max(0, vert.dot(solarVector) / vert.length() / solarVector.length() / (2 * std.math.pi));
				// TODO: Direct Normal Irradiance? when we have atmosphere
				const solarIrradiance = options.solarConstant * solarCoeff * meanPointArea; // W = J.s-1
				// So, we get heat transfer in J
				const heatTransfer = solarIrradiance * dt;
				const temperatureGain = heatTransfer / heatCapacity; // K
				newTemp[i] += temperatureGain;
			}

			// Thermal radiation with Stefan-Boltzmann law
			{
				const stefanBoltzmannConstant = 0.00000005670374; // W.m-2.K-4
				// water emissivity: 0.96
				// limestone emissivity: 0.92
				const emissivity = 0.93; // took a value between the two
				const radiantEmittance = stefanBoltzmannConstant * temp * temp * temp * temp * emissivity; // W.m-2
				const heatTransfer = radiantEmittance * meanPointArea * dt; // J
				const temperatureLoss = heatTransfer / heatCapacity; // K
				newTemp[i] -= temperatureLoss;
			}
		}

		// Finish by swapping the new temperature
		std.mem.swap([]f32, &self.temperature, &self.newTemperature);

		var iteration: usize = 0;
		while (iteration < 2) : (iteration += 1) {
			const newElev = self.newWaterElevation;
			std.mem.copy(f32, newElev, self.waterElevation);

			// Do some liquid simulation
			for (self.vertices) |_, i| {
				// only fluid if it's not ice
				if (self.temperature[i] > 273.15 or true) {
					const height = self.waterElevation[i];
					const totalHeight = self.elevation[i] + height;

					const factor = 6 / 0.5 / options.timeScale;
					var shared = height / factor / 10;
					var numShared: f32 = 0;
					if (self.waterElevation[i] < 0) {
						std.log.warn("WTFFFF", .{});
						std.process.exit(0);
					}

					if (true) {numShared += self.sendWater(self.getNeighbour(i, .ForwardLeft), shared, totalHeight);
					numShared += self.sendWater(self.getNeighbour(i, .ForwardRight), shared, totalHeight);
					numShared += self.sendWater(self.getNeighbour(i, .BackwardLeft), shared, totalHeight);
					numShared += self.sendWater(self.getNeighbour(i, .BackwardRight), shared, totalHeight);
					numShared += self.sendWater(self.getNeighbour(i, .Left), shared, totalHeight);
					numShared += self.sendWater(self.getNeighbour(i, .Right), shared, totalHeight);
					newElev[i] -= numShared;}
				}
			}

			std.mem.swap([]f32, &self.waterElevation, &self.newWaterElevation);
		}
		// std.log.info("water elevation at 123: {d}", .{ newElev[123] });
	}

	fn sendWater(self: Planet, target: usize, shared: f32, totalHeight: f32) f32 {
		const targetTotalHeight = self.elevation[target] + self.waterElevation[target];
		if (totalHeight > targetTotalHeight) {
			var transmitted = std.math.min(shared, shared * (totalHeight - targetTotalHeight) / 50);
			if (transmitted < 0) {
				std.log.info("shared: {d}, total height: {d}, target total height: {d} difference: {d}", .{ shared, totalHeight, targetTotalHeight, totalHeight - targetTotalHeight });
				std.process.exit(0);
			}
			self.newWaterElevation[target] += transmitted;
			return transmitted;
		} else {
			return 0;
		}
	}

	pub fn deinit(self: Planet) void {
		self.lifeforms.deinit();
		self.allocator.free(self.bufData);

		self.allocator.free(self.elevation);
		self.allocator.free(self.newWaterElevation);
		self.allocator.free(self.waterElevation);
		self.allocator.free(self.newTemperature);
		self.allocator.free(self.temperature);
		
		self.allocator.free(self.verticesNeighbours);
		self.allocator.free(self.vertices);
		self.allocator.free(self.indices);
	}

};
