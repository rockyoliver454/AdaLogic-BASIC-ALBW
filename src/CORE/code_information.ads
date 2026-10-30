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

pragma Ada_2012;
pragma SPARK_Mode (On);

--  =========================================================================
--  AdaLogic_BASIC: Forge Metrics Scanner
--  Provides a built-in utility to scan the engine's source code
--  and report metrics (Line counts, file counts) to the console.
--  =========================================================================

package Code_Information is

   -- Resets the running tallies tae zero
   procedure Reset_Metrics;
   
   -- Scans a target (file or directory) and adds it tae the running tally
   procedure Scan_Target (Target_Path : String);
   
   -- Prints the final combined tally
   procedure Print_Metrics;

end Code_Information;
