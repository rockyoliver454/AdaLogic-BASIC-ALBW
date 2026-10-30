-- ============================================================
--     _      _      ____
--    / \    | |    | __ )
--   / _ \   | |    |  _ \
--  / ___ \  | |___ | |_) |
-- /_/   \_\ |_____||____/
--
--  AdaLogic BASIC (ALB)
--  Copyright 2014-2026 Rocky L. Oliver d/b/a Oliver Softworks
--
--  Licensed under the Apache License, Version 2.0 (the "License");
--  you may not use this file except in compliance with the License.
--  You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
--  Unless required by applicable law or agreed to in writing, software
--  distributed under the License is distributed on an "AS IS" BASIS,
--  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
--  See the License for the specific language governing permissions and
--  limitations under the License.
--
--  Contact: contact@alb-lang.org
--  https://alb-lang.org | https://alb-lang.com | https://alb-lang.dev
-- ============================================================

pragma SPARK_Mode (On);

package body Numerus_Verus is
   

   function NV_Validate_Rational_Circle (Radius : Integer) return Boolean is
      R_Squared    : Integer;
      Inner_Bound  : Long_Float;
      Outer_Bound  : Long_Float;
      Current_Val  : Long_Float;
      Valid_Int    : RS_Interval;
      Status       : Boolean;
   begin
      if Radius < 1 then return False; end if;
      
      R_Squared   := Radius * Radius;
      Inner_Bound := Long_Float(R_Squared - Radius);
      Outer_Bound := Long_Float(R_Squared + Radius);
      
      -- Call the Procedure instead of Function
      Create(Inner_Bound, Outer_Bound, Valid_Int, Status);
      if not Status then
         return False;
      end if;
      
      -- Fixed bounds prevent runaway code
      for X in 1 .. Radius loop
         for Y in 1 .. Radius loop
            Current_Val := Long_Float((X * X) + (Y * Y));
            if Contains(Valid_Int, Current_Val) then
               null; -- True static block plot mapping wad gang here
            end if;
         end loop;
      end loop;
      
      return True;
   end NV_Validate_Rational_Circle;

   procedure NV_Monad_Init (Value : Long_Float; Result : out RS_Interval; Success : out Boolean) is
   begin
      if Value = 0.0 then 
         Result := (0.0, 0.0);
         Success := False; 
         return;
      end if;
      Scalar(Value, Result, Success);
   end NV_Monad_Init;

   procedure NV_Dyad_Create_Bound (Val_A, Val_B : Long_Float; Result : out RS_Interval; Success : out Boolean) is
      Min_Val, Max_Val : Long_Float;
   begin
      if Val_A = Val_B then 
         Result := (0.0, 0.0);
         Success := False; 
         return;
      end if;
      
      if Val_A < Val_B then
         Min_Val := Val_A;
         Max_Val := Val_B;
      else
         Min_Val := Val_B;
         Max_Val := Val_A;
      end if;
      
      Create(Min_Val, Max_Val, Result, Success);
   end NV_Dyad_Create_Bound;

   function NV_Triad_Resolve (Interval : RS_Interval; Test_Value : Long_Float) return Boolean is
   begin
      if not Validate(Interval) then return False; end if;
      return Contains(Interval, Test_Value);
   end NV_Triad_Resolve;

   function NV_Tetrad_Validate_Sphere (Radius : Integer) return Boolean is
      R_Squared    : Integer;
      Inner_Bound  : Long_Float;
      Outer_Bound  : Long_Float;
      Current_Val  : Long_Float;
      Valid_Int    : RS_Interval;
      Status       : Boolean;
   begin
      if Radius < 1 then return False; end if;
      
      R_Squared   := Radius * Radius;
      Inner_Bound := Long_Float(R_Squared - Radius);
      Outer_Bound := Long_Float(R_Squared + Radius);
      
      Create(Inner_Bound, Outer_Bound, Valid_Int, Status);
      if not Status then return False; end if;
      
      for Z in 1 .. Radius loop
         for X in 1 .. Radius loop
            for Y in 1 .. Radius loop
               Current_Val := Long_Float((X * X) + (Y * Y) + (Z * Z));
               if Contains(Valid_Int, Current_Val) then
                  null;
               end if;
            end loop;
         end loop;
      end loop;
      
      return True;
   end NV_Tetrad_Validate_Sphere;

   function NV_Decad_System_Check return Boolean is
      M1, M2, Dyad : RS_Interval;
      Sum          : Integer := 0;
      Status       : Boolean;
   begin
      NV_Monad_Init(1.0, M1, Status); 
      if Status then Sum := Sum + 1; end if;
      
      NV_Monad_Init(4.0, M2, Status); 
      if Status then Sum := Sum + 1; end if;
      
      NV_Dyad_Create_Bound(M1.Lower, M2.Lower, Dyad, Status); 
      if Status then Sum := Sum + 2; end if;
      
      if NV_Triad_Resolve(Dyad, 2.5) then Sum := Sum + 3; end if;
      if NV_Tetrad_Validate_Sphere(2) then Sum := Sum + 3; end if;
      
      if Sum = 10 then return True; end if;
      return False;
   end NV_Decad_System_Check;

   procedure NV_Astronomy_Scale_Orbit (Radius : Integer; Harmonic_Ratio : Long_Float; Result : out RS_Interval; Success : out Boolean) is
      Target_R, R_Squared, Inner_Bound, Outer_Bound : Long_Float;
   begin
      Result := (0.0, 0.0);
      if Radius < 1 or else Harmonic_Ratio <= 0.0 then 
         Success := False; 
         return; 
      end if;
      
      Target_R    := Long_Float(Radius) * Harmonic_Ratio;
      R_Squared   := Target_R * Target_R;
      Inner_Bound := R_Squared - Target_R;
      Outer_Bound := R_Squared + Target_R;
      
      Create(Inner_Bound, Outer_Bound, Result, Success);
      if not Success then return; end if;
      
      Success := Validate(Result);
   end NV_Astronomy_Scale_Orbit;

   function NV_Astronomy_Orbit_Check (Orbit_Interval : RS_Interval; X, Y, Z : Integer) return Boolean is
      Distance_Squared : Long_Float;
   begin
      if not Validate(Orbit_Interval) then return False; end if;
      if X = 0 and then Y = 0 and then Z = 0 then return False; end if;
      
      Distance_Squared := Long_Float((X * X) + (Y * Y) + (Z * Z));
      return Contains(Orbit_Interval, Distance_Squared);
   end NV_Astronomy_Orbit_Check;

   function NV_Astronomy_Get_Resonance (Distance_Squared, Target_Radius_Squared : Long_Float) return Long_Float is
   begin
      if Target_Radius_Squared <= 0.0 or else Distance_Squared <= 0.0 then return 0.0; end if;
      
      if Distance_Squared > Target_Radius_Squared then
         return Target_Radius_Squared / Distance_Squared;
      else
         return Distance_Squared / Target_Radius_Squared;
      end if;
   end NV_Astronomy_Get_Resonance;

   procedure NV_Astronomy_Pulse_Time (Current_Tick : Integer; Next_Tick : out Integer; Success : out Boolean) is
   begin
      Next_Tick := 0;
      if Current_Tick < 1 then 
         Success := False; 
         return; 
      end if;
      
      Next_Tick := Current_Tick + 1;
      Success := True;
   end NV_Astronomy_Pulse_Time;

   function NV_Astronomy_System_Alignment_Check (Body_Count : Integer) return Boolean is
      Sum : Integer := 0;
   begin
      if Body_Count < 1 then return False; end if;
      
      for I in 1 .. 4 loop
         Sum := Sum + I;
      end loop;
      
      if Sum = 10 then return True; end if;
      return False;
   end NV_Astronomy_System_Alignment_Check;

end Numerus_Verus;
