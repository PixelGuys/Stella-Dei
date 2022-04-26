const std = @import("std");
const za = @import("zalgebra");
const Planet = @import("planet.zig").Planet;
const ObjLoader = @import("../ObjLoader.zig");
const Allocator = std.mem.Allocator;
const Vec3 = za.Vec3;

var rabbitMesh: ?ObjLoader.Mesh = null;

const Genome = struct {

};

pub const Lifeform = struct {
	position: Vec3,
	velocity: Vec3 = Vec3.zero(),
	kind: Kind,
	state: State = .wander,
	/// Game time at which the lifeform was born
	timeBorn: f64,
	prng: std.rand.DefaultPrng,
	/// The minimum bar for a given rabbit's sexual attractiveness
	/// This goes up the more there are attemps at mating
	/// This goes down naturally over time (although this has a
	/// minimum depending on genome)
	sexualCriteria: f32 = 0.1,
	genome: Genome = .{},

	pub const Kind = enum {
		Rabbit
	};

	pub const State = union(enum) {
		wander: void,
		go_to_point: usize,
		gestation: struct {
			/// Game time at which the lifeform started being 'pregnant'
			since: f64
		},
	};

	pub fn init(allocator: Allocator, position: Vec3, kind: Kind, gameTime: f64) !Lifeform {
		// init the mesh
		switch (kind) {
			.Rabbit => {
				if (rabbitMesh == null) {
					const mesh = try ObjLoader.readObjFromFile(allocator, "assets/rabbit/rabbit.obj");
					rabbitMesh = mesh;
				}
			}
		}
		return Lifeform {
			.position = position,
			.kind = kind,
			.prng = std.rand.DefaultPrng.init(246),
			.timeBorn = gameTime
		};
	}

	pub fn getMesh(self: Lifeform) ObjLoader.Mesh {
		return switch (self.kind) {
			.Rabbit => rabbitMesh.?
		};
	}

	/// Duration of gestations in in-game seconds
	const GESTATION_DURATION: f64 = 86400; // 1 day
	const SEXUAL_MATURITY_AGE: f64 = 86400 / 2; // 12 hours

	pub fn aiStep(self: *Lifeform, planet: *Planet, options: Planet.SimulationOptions) void {
		const pointIdx = planet.getNearestPointTo(self.position);
		const point = planet.transformedPoints[pointIdx];
		const random = self.prng.random();

		const isInDeepWater = planet.waterElevation[pointIdx] > 1 and planet.temperature[pointIdx] > 273.15;
		const isFrying = planet.temperature[pointIdx] > 273.15 + 60.0;
		const age = options.gameTime - self.timeBorn;
		var shouldDie: bool = isInDeepWater or isFrying or age > 10 * 86400;

		if (self.sexualCriteria > 0.3) {
			// lowers of 0.001 by in game second
			self.sexualCriteria -= 0.000001 * options.timeScale;
			self.sexualCriteria = std.math.max(0.3, self.sexualCriteria);
		}

		switch (self.state) {
			.wander => {
				if (planet.temperature[pointIdx] > 273.15 + 30.0) { // Above 30°C
					// Try to go to a colder point
					var coldestPointIdx: usize = pointIdx;
					var coldestTemperature: f32 = planet.temperature[pointIdx];
					for (planet.getNeighbours(pointIdx)) |neighbourIdx| {
						const isInWater = planet.waterElevation[neighbourIdx] > 0.1 and planet.temperature[neighbourIdx] > 273.15;
						if (planet.temperature[neighbourIdx] + random.float(f32)*1 < coldestTemperature and !isInWater) {
							coldestPointIdx = neighbourIdx;
							coldestTemperature = planet.temperature[neighbourIdx];
						}
					}
					self.state = .{ .go_to_point = coldestPointIdx };
				} else if (planet.temperature[pointIdx] < 273.15 + 5.0) { // Below 5°C
					// Try to go to an hotter point
					var hottestPointIdx: usize = pointIdx;
					var hottestTemperature: f32 = planet.temperature[pointIdx];
					for (planet.getNeighbours(pointIdx)) |neighbourIdx| {
						const isInWater = planet.waterElevation[neighbourIdx] > 0.1 and planet.temperature[neighbourIdx] > 273.15;
						if (planet.temperature[neighbourIdx] - random.float(f32)*1 > hottestTemperature and !isInWater) {
							hottestPointIdx = neighbourIdx;
							hottestTemperature = planet.temperature[neighbourIdx];
						}
					}
					self.state = .{ .go_to_point = hottestPointIdx };
				} else {
					var seekingPartner = false;
					for (planet.lifeforms.items) |*other| {
						// Avoid choosing self as a partner
						if (other != self) {
							const distance = other.position.distance(self.position);
							if (distance < 100 and age >= SEXUAL_MATURITY_AGE) {
								// TODO: cooldown on the sexual activity
								// TODO: have sexual attractivity depend partially on a gene
								const sexualAttractivity = 0.4 + random.float(f32) * 0.1;
								if (sexualAttractivity >= other.sexualCriteria) {
									const number = random.intRangeLessThanBiased(u8, 0, 100);
									if (number == 0) { // 1/100 chance
										// have a baby if it's not already pregnant
										if (other.state != .gestation) {
											std.log.info("a rabbit got pregnant", .{});
											other.state = .{ .gestation = .{
												.since = options.gameTime
											}};
										}
									} else {
										// The other gets more fed up by the attempts
										other.sexualCriteria += 0.05;
									}
								}
							} else if (distance < 400 and other.sexualCriteria < 0.35) {
								// lookup the partner
								const targetIdx = planet.getNearestPointTo(other.position);
								self.state = .{ .go_to_point = targetIdx };
								seekingPartner = true;
							}
						}
					}

					if (!seekingPartner) {
						// If the lifeform hasn't found any partner to mate with,
						// just wander around to one of the current point's neighbours
						const neighbours = planet.getNeighbours(pointIdx);
						var attempts: usize = 1;
						var number = random.intRangeLessThanBiased(u8, 0, 6);
						while (planet.waterElevation[neighbours[number]] > 0.1) {
							if (attempts == 6) break;
							number = random.intRangeLessThanBiased(u8, 0, 6);
							attempts += 1;
						}
						self.state = .{ .go_to_point = neighbours[number] };
					}
				}
			},
			.go_to_point => |targetIdx| {
				const target = planet.transformedPoints[targetIdx];
				const direction = target.sub(point);
				self.velocity = direction.norm().scale(4); // 4km/frame
				if (direction.length() < 10) {
					self.state = .wander;
				}
			},
			.gestation => |info| {
				if (options.gameTime > info.since + GESTATION_DURATION) {
					std.log.info("a rabbit got a baby", .{});

					const number = random.intRangeLessThanBiased(u8, 0, 6);
					if (number == 0) { // 1/6 chance to die
						shouldDie = true;
					}
					self.state = .wander;
					self.sexualCriteria = 25;
					
					// doesn't need allocator (and thus can't throw error) as the resource for
					// the current kind is already loaded
					const lifeform = Lifeform.init(undefined, point, self.kind, options.gameTime) catch unreachable;
					planet.lifeforms.append(lifeform) catch {
						// TODO?
					};
					// Must return as the array list may have expanded, in which case
					// the 'self' pointer is now invalid!
					return;
				}
			}
		}
		self.position = self.position.add(self.velocity);

		if (self.position.length() < point.length()) {
			self.position = self.position.norm().scale(point.length());
			self.velocity = Vec3.zero();
		} else {
			// TODO: accurate gravity
			self.velocity = self.velocity.add(
				self.position.norm().negate() // towards the planet
			);
		}

		if (shouldDie) {
			const index = blk: {
				for (planet.lifeforms.items) |*lifeform, idx| {
					if (lifeform == self) break :blk idx;
				}
				// already removed???
				return;
			};

			// we're iterating so avoid a swapRemove
			_ = planet.lifeforms.orderedRemove(index);
		}
	}
};
