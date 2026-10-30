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

package body Bin_Types is

   procedure Create_Span (Block_ID, Start_Offset, Span_Length : Natural; Result : out Binary_Span; Success : out Boolean) is
   begin
      if Block_ID = 0 or else Span_Length = 0 then
         Result := (0, 0, 0);
         Success := False;
         return;
      end if;

      Result := (Block_Index => Block_ID, Offset => Start_Offset, Length => Span_Length);
      Success := True;
   end Create_Span;

   function Validate_Access (Span : Binary_Span; Read_Offset, Data_Size : Natural) return Boolean is
      RS_Stat : Boolean;
      Ival    : RS_Interval;
      End_Pos : Natural;
   begin
      if Span.Length = 0 or else Data_Size = 0 then
         return False;
      end if;

      if Natural'Last - Read_Offset < Data_Size then
         return False;
      end if;

      End_Pos := Read_Offset + Data_Size;

      -- FIX: Shift bounds tae 1-based tae pacify Range_Spec. 
      -- If length is 1, use Scalar tae avoid identical bounds failure.
      if Span.Length = 1 then
         Scalar(1.0, Ival, RS_Stat);
      else
         Create (1.0, Long_Float(Span.Length), Ival, RS_Stat);
      end if;
      
      if not RS_Stat then return False; end if;

      if not Contains(Ival, Long_Float(End_Pos)) then
         return False;
      end if;

      return True;
   end Validate_Access;

end Bin_Types;
